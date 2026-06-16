#!/usr/bin/env python3
"""
Smoke test for the Anthropic system-role hoisting fix.

Verifies that a /v1/messages request containing a ``role="system"`` entry
*inside* the messages array (the shape Claude Code sends when targeting Opus
models) no longer fails with HTTP 422.

Two modes:

1. LIVE (default): sends a real HTTP request to a running gateway.
       python smoke_test.py --base-url http://localhost:8000 --api-key YOUR_KEY
   Env fallbacks: GATEWAY_URL, PROXY_API_KEY.

2. LOCAL (no server / no credentials needed): validates the Pydantic model
   directly to confirm the system message is hoisted into the top-level
   ``system`` field.
       python smoke_test.py --local

Exit code is 0 on success, 1 on failure (handy for CI).
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


# The exact payload shape that previously triggered the 422 on Opus models:
# a message with role="system" sitting inside the `messages` array.
OPUS_SYSTEM_IN_ARRAY = {
    "model": "claude-opus-4.5",
    "max_tokens": 64,
    "messages": [
        {"role": "user", "content": "Say hello in one word."},
        {"role": "system", "content": "You are concise."},
    ],
}


def run_local() -> bool:
    """Validate the fix at the model layer (no server, no credentials)."""
    print("[local] Importing AnthropicMessagesRequest ...")
    try:
        from kiro.models_anthropic import AnthropicMessagesRequest
    except Exception as exc:  # pragma: no cover - import guard
        print(f"[local] FAIL: could not import model: {exc}")
        return False

    print("[local] Parsing the Opus 'system-in-array' payload ...")
    try:
        req = AnthropicMessagesRequest(**OPUS_SYSTEM_IN_ARRAY)
    except Exception as exc:
        print(f"[local] FAIL: request still rejected (the bug): {exc}")
        return False

    roles = [m.role for m in req.messages]
    print(f"[local] messages roles after parse: {roles}")
    print(f"[local] top-level system: {req.system!r}")

    if "system" in roles:
        print("[local] FAIL: a system role is still present in messages")
        return False
    if not req.system or "concise" not in str(req.system):
        print("[local] FAIL: system content was not hoisted into `system`")
        return False

    print("[local] PASS: system message hoisted correctly.")
    return True


def _post_json(url: str, headers: dict, payload: dict, timeout: int = 30):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")


def run_live(base_url: str, api_key: str) -> bool:
    """Hit a running gateway and assert the Opus payload is accepted."""
    base_url = base_url.rstrip("/")

    # 1) Health check (best-effort, non-fatal).
    try:
        with urllib.request.urlopen(f"{base_url}/health", timeout=10) as resp:
            print(f"[live] /health -> {resp.status}")
    except Exception as exc:
        print(f"[live] WARN: /health check failed ({exc}); continuing.")

    # 2) The Opus 'system-in-array' request.
    headers = {
        "content-type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    print("[live] POST /v1/messages with system-role message inside messages ...")
    status, body = _post_json(f"{base_url}/v1/messages", headers, OPUS_SYSTEM_IN_ARRAY)
    print(f"[live] status: {status}")

    if status == 422:
        print(f"[live] FAIL: still 422 (the bug). Body: {body[:400]}")
        return False
    if status in (401, 403):
        print(f"[live] FAIL: auth error {status} - check --api-key/PROXY_API_KEY.")
        return False
    if status >= 500:
        print(f"[live] WARN: upstream {status} (not a validation error). Body: {body[:400]}")
        print("[live] PASS (validation): request passed the 422 gate.")
        return True

    print("[live] PASS: request accepted (no 422).")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke test for system-role hoisting fix.")
    parser.add_argument("--local", action="store_true",
                        help="Validate the Pydantic model directly (no server needed).")
    parser.add_argument("--base-url", default=os.environ.get("GATEWAY_URL", "http://localhost:8000"),
                        help="Gateway base URL (env: GATEWAY_URL).")
    parser.add_argument("--api-key", default=os.environ.get("PROXY_API_KEY", ""),
                        help="Proxy API key (env: PROXY_API_KEY).")
    args = parser.parse_args()

    if args.local:
        ok = run_local()
    else:
        if not args.api_key:
            print("ERROR: provide --api-key or set PROXY_API_KEY (or use --local).")
            return 1
        ok = run_live(args.base_url, args.api_key)

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
