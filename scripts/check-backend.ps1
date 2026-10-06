param([string]$ApiBaseUrl = 'http://192.168.13.10:3000/api/v1')

# Answers "is the backend up, and can my phone reach it?" in one command.
#
# Checks four layers separately, because they fail for different reasons and
# telling them apart saves a lot of guessing:
#   1. Is the API process running on this machine?
#   2. Does /health answer, and is the DATABASE reachable?
#   3. Can the API see real data? (stops are public, so no token is needed)
#   4. Can the PHONE reach it? (curl run on the device, not the PC)
#
# Layer 4 is the one that catches "works on my laptop, fails on the handset" —
# a phone on different Wi-Fi, or a host missing from network_security_config.

$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$pidFile = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.pid'
$out = "$env:TEMP\addis_backend_check.txt"
$L = @("=== backend check @ $(Get-Date -Format o) ===")

# ── 1. process ─────────────────────────────────────────────────────────────
$pidValue = if (Test-Path $pidFile) { Get-Content $pidFile -EA SilentlyContinue } else { $null }
$running = $false
if ($pidValue) {
  $proc = Get-Process -Id $pidValue -EA SilentlyContinue
  $running = $null -ne $proc
}
$L += "process: pid=$(if($pidValue){$pidValue}else{'none'}) running=$running"
if (-not $running) {
  $L += '  -> start it with: scripts\start-backend.ps1'
}

# ── 2. health from this machine ────────────────────────────────────────────
$healthUrl = $ApiBaseUrl -replace '/api/v1$', '/api/v1/health'
try {
  $h = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 8
  $L += "health(PASSING): $($h | ConvertTo-Json -Compress)"
} catch {
  $L += "health(FAILING): $($_.Exception.Message)"
}

# ── 3. real data ──────────────────────────────────────────────────────────
# /stops is deliberately public: a passenger must be able to see the network
# and a fare without an account. If this 401s, browsing is broken for everyone.
try {
  $s = Invoke-RestMethod -Uri "$ApiBaseUrl/stops" -TimeoutSec 8
  $L += "stops(public): $($s.stops.Count) returned"
} catch {
  $code = $_.Exception.Response.StatusCode.value__
  $L += "stops(public) FAILED: status=$code  (401 here means the guard is still applied)"
}

# ── 4. from the phone ─────────────────────────────────────────────────────
$devices = (& $adb devices 2>&1 | Out-String)
if ($devices -notmatch 'device$') {
  $L += 'phone: no device connected (skipped)'
} else {
  $phoneUrl = $ApiBaseUrl -replace '^http://192\.168\.13\.10', 'http://192.168.13.10'
  $code = (& $adb shell "curl -s -m 8 -o /dev/null -w '%{http_code}' $phoneUrl/stops" 2>&1 | Out-String).Trim()
  $L += "phone -> /stops: status=$code  (200 means reachable; 401 means reachable but guarded)"
}

$L += '--- how to read this ---'
$L += 'process running=false  -> the API is down; run start-backend.ps1'
$L += 'health database=failed -> API is up but Postgres is not; check docker compose'
$L += 'phone status=000       -> the handset cannot reach this machine (Wi-Fi / firewall)'
$L += 'stops 401             -> browsing needs auth, which is a regression'

Set-Content -Path $out -Value $L -Encoding UTF8
Write-Output "wrote $out"
