param(
  [string]$Phone = '+251911234567',
  [string]$Api = 'http://127.0.0.1:3000/api/v1'
)

# Prints a login OTP for the passenger app.
#
#   .\scripts\get-otp.ps1
#   .\scripts\get-otp.ps1 -Phone +251912345678
#
# There is deliberately no fixed demo code. OtpService draws a fresh six-digit
# number per request with randomInt(), persists only a salted SHA-256 hash, and
# expires it after five minutes. A hardcoded code would have to be special-cased
# in the verification path, which is the one piece of code that must stay
# identical between dev and production. So the code is printed by the server
# (OTP_DEV_ECHO=true in .env) and this script reads it back out.
#
# That makes the log the transport: request plus read is exactly what a person
# watching the console would do, so there is no test-only path in the API itself.

$ErrorActionPreference = 'Continue'
$log = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.log'

# Remember where the log ended BEFORE the request, then read only what the server
# appends afterwards. Searching the whole file would happily return the previous
# sign-in's code, which is still a plausible six digits and produces a "wrong
# code" failure that looks like a bug in the verification path.
$offset = 0
if (Test-Path $log) { $offset = (Get-Item $log).Length }

try {
  Invoke-RestMethod "$Api/auth/request-otp" -Method Post -TimeoutSec 15 `
        -ContentType 'application/json' -Body (@{ phone = $Phone } | ConvertTo-Json) | Out-Null
} catch {
  $status = 0
  try { $status = [int]$_.Exception.Response.StatusCode } catch { }
  if ($status -eq 429) {
    # 45s resend cooldown, 5 per hour. Not a fault worth debugging.
    Write-Output "RATE LIMITED for $Phone - wait about 45s (hourly cap is 5 codes)."
    exit 1
  }
  Write-Output "request-otp failed ($status): $($_.Exception.Message)"
  exit 1
}

# The server logs the code asynchronously, so poll briefly rather than reading once
# and concluding, as the first attempt here did, that nothing was echoed.
$otp = $null
for ($i = 0; $i -lt 20 -and -not $otp; $i++) {
  Start-Sleep -Milliseconds 250
  if (-not (Test-Path $log)) { continue }
  $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
  $sr = $null
  try {
    $null = $fs.Seek($offset, 'Begin')
    $sr = New-Object System.IO.StreamReader($fs)
    $tail = $sr.ReadToEnd()
  } finally {
    if ($sr) { $sr.Close() } else { $fs.Close() }
  }

  $pattern = '\[DEV OTP\]\s*phone=' + [regex]::Escape($Phone) + '\s*code=(\d{6})'
  $m = [regex]::Match($tail, $pattern)
  if ($m.Success) { $otp = $m.Groups[1].Value }
}

if (-not $otp) {
  Write-Output "No [DEV OTP] line appeared in $log after requesting a code."
  Write-Output 'Check OTP_DEV_ECHO=true is set in backend\.env and that the server'
  Write-Output 'was restarted after it was set.'
  exit 1
}

Write-Output "phone: $Phone"
Write-Output "otp  : $otp"
Write-Output 'valid 5 minutes, 5 attempts; the account is created on first sign-in'
exit 0