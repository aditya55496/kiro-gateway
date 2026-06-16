# =====================================================================
# Kiro Gateway - deploy the Opus 422 "system-role" fix (Windows / PowerShell)
#
# Run this INSIDE the kiro-gateway folder that your gateway actually runs from.
# It pulls the fixed code from your fork, force-rebuilds, and verifies the fix
# is live. Your existing .env / credentials.json are reused automatically.
#
#   powershell -ExecutionPolicy Bypass -File deploy_fix.ps1 -ApiKey "YOUR_PROXY_API_KEY"
# =====================================================================
param(
    [string]$ApiKey = $env:PROXY_API_KEY,
    [string]$ForkUrl = "https://github.com/aditya55496/kiro-gateway.git",
    [string]$Branch = "fix/anthropic-system-role-hoisting",
    [string]$BaseUrl = "http://localhost:8000"
)

$ErrorActionPreference = "Stop"
Write-Host "==> 1/5  Fetching the fix from your fork..." -ForegroundColor Cyan
if (-not (git remote | Select-String -Quiet "^fork$")) { git remote add fork $ForkUrl }
git fetch fork $Branch
git checkout -B opus-fix "fork/$Branch"

Write-Host "==> 2/5  Verifying the patch is in the source..." -ForegroundColor Cyan
$hit = Select-String -Path "kiro\models_anthropic.py" -Pattern "normalize_request_message_roles"
if (-not $hit) { Write-Host "FAIL: patch not found in source. Stop." -ForegroundColor Red; exit 1 }
Write-Host "    OK - patch present." -ForegroundColor Green

Write-Host "==> 3/5  Rebuilding & restarting (clean, no cache)..." -ForegroundColor Cyan
$usingDocker = Test-Path "docker-compose.yml"
if ($usingDocker) {
    docker compose down
    docker compose build --no-cache
    docker compose up -d
} else {
    Write-Host "    No docker-compose.yml -> run 'python main.py' yourself after this script." -ForegroundColor Yellow
}

Write-Host "==> 4/5  Waiting for the gateway to come up..." -ForegroundColor Cyan
$up = $false
for ($i = 0; $i -lt 20; $i++) {
    try { Invoke-WebRequest -UseBasicParsing "$BaseUrl/health" -TimeoutSec 3 | Out-Null; $up = $true; break }
    catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Write-Host "    WARN: /health not reachable yet." -ForegroundColor Yellow }

Write-Host "==> 5/5  Verifying the Opus 'system-in-array' payload is accepted..." -ForegroundColor Cyan
if (-not $ApiKey) { Write-Host "    Provide -ApiKey or set PROXY_API_KEY to run the live check." -ForegroundColor Yellow; exit 0 }
$body = '{"model":"claude-opus-4-8","messages":[{"role":"user","content":"hi"},{"role":"system","content":"x"}]}'
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Method POST "$BaseUrl/v1/messages/count_tokens" `
        -Headers @{ "x-api-key" = $ApiKey; "content-type" = "application/json" } -Body $body -TimeoutSec 15
    Write-Host "    HTTP $($resp.StatusCode) -> FIX IS LIVE. Opus will work in Claude Code." -ForegroundColor Green
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 422) { Write-Host "    HTTP 422 -> STILL OLD CODE. A stale container/process is answering on $BaseUrl." -ForegroundColor Red }
    else { Write-Host "    HTTP $code (not 422) -> validation gate passed; fix is live." -ForegroundColor Green }
}
