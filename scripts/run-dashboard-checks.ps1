# Boots the API once, then runs every dashboard check against it.
#
# verify-dashboard.ps1 and verify-dashboard-page.ps1 assume a server is already
# listening and do not start one, and the browser check reads OTP codes out of
# backend/server.log. Running them separately meant each had to be paired with a
# manual boot, which is exactly the step that was being forgotten — they had been
# reporting results from stale output files.
#
# DATABASE_URL is removed before starting. It is present in this shell, inherited
# from an unrelated project, and dotenv deliberately does NOT override a value
# that is already set, so leaving it in place makes the boot fail on the env guard.
# backend/.env then supplies the real value.
$ErrorActionPreference = 'Continue'
$root  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport'
$base  = Join-Path $root 'backend'
$log   = Join-Path $base 'server.log'
$out   = "$env:TEMP\addis_dashrun.txt"

Set-Content -Path $out -Value ('DASHBOARD RUN ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8
function Say($s) { Add-Content -Path $out -Value $s -Encoding utf8 }

# 1. Free the port, so a leftover server from an interrupted run cannot make the
#    checks talk to code that is not the one just built.
foreach ($p in @(Get-NetTCPConnection -LocalPort 3000 -State Listen -EA 0 |
                 Select-Object -ExpandProperty OwningProcess -Unique)) {
  Stop-Process -Id $p -Force -EA 0
  Say ('stopped stale pid ' + $p)
}
Start-Sleep -Seconds 2

# 2. Truncate so an OTP code from an earlier run can never be mistaken for this
#    run's, then start the server appending to the path both checks read.
Set-Content -Path $log -Value '' -Encoding utf8
Remove-Item Env:\DATABASE_URL -EA 0
$env:OTP_DEV_ECHO = 'true'
# The server is started through cmd.exe, not as a PowerShell job, and this matters
# for more than convenience.
#
# A PowerShell job that redirects into server.log holds an EXCLUSIVE handle on it
# for the job's whole life. readFileSync in the browser check then fails with
# EBUSY/EPERM, readServerLog() swallows that in its catch and returns '', and the
# check dies with "no OTP echoed in the server log" — while the code is sitting in
# the log in plain sight. PowerShell's own Get-Content and Select-String open with
# shared access, which is why every PowerShell check kept passing and only the
# Node check failed. The error message points at the log; the fault is the handle.
#
# cmd's `>>` opens the file shared, so the writer and the reader coexist. The
# encoding is UTF-8, which is also what readFileSync expects.
Remove-Item Env:\DATABASE_URL -EA 0
$env:OTP_DEV_ECHO = 'true'
$null = Start-Process -FilePath 'cmd.exe' `
  -ArgumentList '/c', ('node dist/main.js >> "' + $log + '" 2>&1') `
  -WorkingDirectory $base -WindowStyle Hidden -PassThru

# 3. Wait for readiness. Generous, because the sandbox tears down a foreground
#    command quickly and a premature "not up" would cascade into every later step
#    reporting failures that have nothing to do with the page.
$up = $false
for ($i = 0; $i -lt 30 -and -not $up; $i++) {
  Start-Sleep -Seconds 2
  try {
    if ((Invoke-WebRequest 'http://127.0.0.1:3000/api/v1/health' -TimeoutSec 3 `
         -UseBasicParsing).StatusCode -eq 200) { $up = $true }
  } catch { }
}
Say ('server_up=' + $up)

if ($up) {
  Say '--- api check ---'
  & (Join-Path $root 'scripts\verify-dashboard.ps1') 2>&1 | Out-Null
  Say ('api_check_bytes=' + (Get-Item "$env:TEMP\addis_dash_api.txt" -EA 0).Length)

  Say '--- page check ---'
  & (Join-Path $root 'scripts\verify-dashboard-page.ps1') 2>&1 | Out-Null
  Say ('page_check_bytes=' + (Get-Item "$env:TEMP\addis_dash_page.txt" -EA 0).Length)

  Say '--- browser check ---'
  # The API check just spent an OTP request on +251911000001. The browser check
  # signs in as the same number, and the 45s resend cooldown (correctly) refuses
  # it — which surfaces as "no OTP echoed in the server log", a message that
  # blames the log rather than the limit that actually fired.
  #
  # The history is cleared rather than the cooldown lowered: the limit is right and
  # must not be weakened for a test. Deleting the rows resets both the cooldown
  # and the hourly counter, which is exactly the "fresh code" the check needs.
  & (Join-Path $root 'scripts\clear-otp.ps1') 2>&1 | Out-Null
  Push-Location $root
  try {
    $b = & node 'scripts\browser-dashboard-check.mjs' 2>&1 | Out-String
    Set-Content -Path "$env:TEMP\addis_browser_run.txt" -Value $b -Encoding utf8
    $summary = ($b -split "`n" | Where-Object { $_ -match 'passed, \d+ failed' })
    Say ('browser_summary=' + ($summary -join ' ').Trim())
  } finally { Pop-Location }
} else {
  Say 'SERVER DID NOT START - downstream checks skipped, not failed'
}

foreach ($p in @(Get-NetTCPConnection -LocalPort 3000 -State Listen -EA 0 |
                 Select-Object -ExpandProperty OwningProcess -Unique)) {
  Stop-Process -Id $p -Force -EA 0
}
Say 'DONE'