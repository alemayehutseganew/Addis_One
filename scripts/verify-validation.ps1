# Focused check of the validation (inspector scanner) surface.
#
# Split out from the full gate deliberately: the sandbox tears down a foreground
# command after roughly a minute, and the combined gate was being killed midway
# through the OTP round-trips. This script does the minimum that proves the new
# module works, and finishes inside that window.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_val.log"
$out = "$env:TEMP\addis_val_report.txt"

function Rep($n, $e, $a) {
  Add-Content -Path $out -Value ('{0,-32} expected={1,-14} actual={2}' -f $n, $e, $a) -Encoding utf8
}
Set-Content -Path $out -Value ('VALIDATION GATE ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8

Set-Location $base
$job = Start-Job -ScriptBlock {
  param($d, $f)
  Set-Location $d
  $env:DATABASE_URL = $null
  $env:OTP_DEV_ECHO = 'true'
  node dist/main.js *> $f
} -ArgumentList $base, $log

$up = $false
1..12 | ForEach-Object {
  if (-not $up) {
    Start-Sleep -Seconds 2
    try { if ((Invoke-WebRequest "$api/health" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { $up = $true } } catch { }
  }
}
Rep 'server boots' 200 $(if ($up) { 200 } else { 0 })

function Otp($phone) {
  $null = Invoke-RestMethod "$api/auth/request-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = $phone } | ConvertTo-Json)
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 250
    $p = (Get-Content $log -Raw -EA 0) -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
    $m = [regex]::Match($p, 'code[=\s:]+(\d{6})')
    if ($m.Success) {
      return (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = $phone; code = $m.Groups[1].Value } | ConvertTo-Json)).accessToken
    }
  }
  return $null
}

if ($up) {
  # The inspector is the role that matters; the seeded admin would pass any gate.
  $t = Otp '+251911000009'
  Rep 'inspector signs in' 'token' $(if ($t) { 'token' } else { 'null' })

  try { $null = Invoke-WebRequest "$api/validation/clock" -TimeoutSec 8 -UseBasicParsing; Rep 'anonymous refused' 401 200 } catch { Rep 'anonymous refused' 401 ([int]$_.Exception.Response.StatusCode) }

  if ($t) {
    $h = @{ Authorization = "Bearer $t" }
    try { $x = Invoke-WebRequest "$api/validation/clock" -Headers $h -TimeoutSec 8 -UseBasicParsing; Rep 'inspector reaches scanner' 200 $x.StatusCode } catch { Rep 'inspector reaches scanner' 200 ('ERR ' + $_.Exception.Message) }

    try {
      $s = Invoke-RestMethod "$api/validation/scan" -Method Post -Headers $h -ContentType 'application/json' -TimeoutSec 15 -Body (@{ qrString = '{"t":"00000000-0000-0000-0000-000000000000","c":"x","i":1,"e":9999999999,"n":"zz","k":"addis-one-2026-01","s":"AAAA"}' } | ConvertTo-Json)
      Rep 'forged scan http' 200 200
      Rep 'forged accepted' 'False' $s.accepted
      Rep 'forged outcome' 'INVALID_SIGNATURE' $s.outcome
      Rep 'forged recorded' 'VAL-' ([string]$s.validationReference).Substring(0, 4)
    } catch { Rep 'forged scan http' 200 ('ERR ' + $_.Exception.Message) }

    try { $null = Invoke-WebRequest "$api/validation/scan" -Method Post -Headers $h -ContentType 'application/json' -TimeoutSec 8 -Body (@{ nope = 'x' } | ConvertTo-Json); Rep 'bad body refused' 400 200 } catch { Rep 'bad body refused' 400 ([int]$_.Exception.Response.StatusCode) }

    try { $m = Invoke-RestMethod "$api/validation/mine" -Headers $h -TimeoutSec 8; Rep 'scan history recorded' 'True' ($m.validations.Count -ge 1) } catch { Rep 'scan history recorded' 'True' ('ERR ' + $_.Exception.Message) }
  }
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0
Add-Content -Path $out -Value 'DONE' -Encoding utf8