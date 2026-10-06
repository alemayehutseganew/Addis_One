$base = 'http://127.0.0.1:3000/api/v1'
$log  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.log'
$out  = "$env:TEMP\addis_authtest.txt"
$lines = @()
$lines += "=== auth flow test @ $(Get-Date -Format o) ==="

$phone = '+251911234567'

function Post-Json($path, $body) {
  try {
    return Invoke-RestMethod -Uri "$base$path" -Method Post `
      -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) `
      -TimeoutSec 20 -ErrorAction Stop
  } catch {
    return @{ __error = $_.Exception.Message }
  }
}

# 1. Request an OTP
$lines += "--- POST /auth/request-otp ---"
$r1 = Post-Json '/auth/request-otp' @{ phone = $phone }
$lines += ($r1 | ConvertTo-Json -Compress)

# 2. Pull the code the server echoed to its log
Start-Sleep -Seconds 1
$code = $null
if (Test-Path $log) {
  $m = Select-String -Path $log -Pattern '\[DEV OTP\].*code=(\d{6})' | Select-Object -Last 1
  if ($m -and $m.Matches.Count) { $code = $m.Matches[0].Groups[1].Value }
}
$lines += "echoed_code=$code"

if (-not $code) {
  $lines += "FAILED: no OTP echoed in server log"
  Set-Content -Path $out -Value $lines -Encoding UTF8
  Write-Output 'done (failed)'
  exit 0
}

# 3. Wrong code must be refused
$lines += "--- POST /auth/verify-otp (wrong code) ---"
$r2 = Post-Json '/auth/verify-otp' @{ phone = $phone; code = '000000' }
$lines += ($r2 | ConvertTo-Json -Compress)

# 4. Correct code must issue a session
$lines += "--- POST /auth/verify-otp (correct) ---"
$r3 = Post-Json '/auth/verify-otp' @{ phone = $phone; code = $code }
$lines += ("ok=" + $r3.ok)
$lines += ("has_access=" + [bool]$r3.accessToken)
$lines += ("has_refresh=" + [bool]$r3.refreshToken)
$lines += ("expires_in=" + $r3.expiresIn)

# 5. /auth/me with the issued token
if ($r3.accessToken) {
  $lines += "--- GET /auth/me ---"
  try {
    $me = Invoke-RestMethod -Uri "$base/auth/me" -Headers @{ Authorization = "Bearer $($r3.accessToken)" } -TimeoutSec 20
    $lines += ($me | ConvertTo-Json -Compress)
  } catch { $lines += "me_error=" + $_.Exception.Message }

  $lines += "--- GET /auth/me (no token) must be 401 ---"
  try {
    Invoke-RestMethod -Uri "$base/auth/me" -TimeoutSec 20 | Out-Null
    $lines += "UNEXPECTED: unauthenticated call succeeded"
  } catch {
    $lines += "unauth_status=" + [int]$_.Exception.Response.StatusCode
  }

  $lines += "--- POST /auth/refresh (rotation) ---"
  $r4 = Post-Json '/auth/refresh' @{ refreshToken = $r3.refreshToken }
  $lines += ("refresh_ok=" + [bool]$r4.accessToken)

  $lines += "--- old refresh token must now be rejected ---"
  $r5 = Post-Json '/auth/refresh' @{ refreshToken = $r3.refreshToken }
  $lines += ("replay_rejected=" + ($null -eq $r5.accessToken))
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output 'done'
