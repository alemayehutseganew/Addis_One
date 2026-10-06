# Live check of the mobility (driver) module, now that trips exist to drive.
#
# The point of these checks is the denials. A driver listing trips proves little;
# a driver being refused another operator's trip, and being refused an illegal
# state change, is the behaviour that actually holds the network together.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_mob.log"
$out = "$env:TEMP\addis_mob_report.txt"

function Rep($n, $e, $a) { Add-Content -Path $out -Value ('{0,-38} expected={1,-14} actual={2}' -f $n, $e, $a) -Encoding utf8 }
function Code($r) { try { [int]$r.StatusCode } catch { 0 } }
Set-Content -Path $out -Value ('MOBILITY ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8

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
    $all = [regex]::Matches($p, 'code[=\s:]+(\d{6})')
    if ($all.Count -gt 0) {
      return (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = $phone; code = $all[$all.Count - 1].Groups[1].Value } | ConvertTo-Json)).accessToken
    }
  }
  return $null
}

if ($up) {
  $drv = Otp '+251911000007'
  $bur = Otp '+251911000001'
  Rep 'driver signs in' 'token' $(if ($drv) { 'token' } else { 'null' })

  if ($drv) {
    $dh = @{ Authorization = "Bearer $drv" }
    $mine = Invoke-RestMethod "$api/driver/trips" -Headers $dh -TimeoutSec 10
    $trips = @($mine.trips)
    Rep 'driver sees own-operator trips' 5 $trips.Count
    # The other operator's bus must never appear in this list.
    Rep 'no foreign vehicle visible' 0 (@($trips | Where-Object { $_.vehiclePlate -eq 'ET-BB-2001' }).Count)
    Rep 'trips expose transitions' 'True' (@($trips | Where-Object { $_.availableTransitions.Count -gt 0 }).Count -ge 1)

    # Start a BOARDING trip: legal.
    $boarding = @($trips | Where-Object { $_.status -eq 'BOARDING' })[0]
    if ($boarding) {
      try { $s = Invoke-RestMethod "$api/driver/trips/$($boarding.id)/start" -Method Post -Headers $dh -TimeoutSec 10; Rep 'start BOARDING trip' 'IN_PROGRESS' $s.status } catch { Rep 'start BOARDING trip' 'IN_PROGRESS' (Code $_.Exception.Response) }
      # Complete it now that it is running.
      try { $c = Invoke-RestMethod "$api/driver/trips/$($boarding.id)/complete" -Method Post -Headers $dh -TimeoutSec 10; Rep 'complete IN_PROGRESS trip' 'COMPLETED' $c.status } catch { Rep 'complete IN_PROGRESS trip' 'COMPLETED' (Code $_.Exception.Response) }
      # A completed trip is terminal: it must not be completable twice.
      try { $null = Invoke-WebRequest "$api/driver/trips/$($boarding.id)/complete" -Method Post -Headers $dh -TimeoutSec 10 -UseBasicParsing; Rep 'complete twice refused' 400 200 } catch { Rep 'complete twice refused' 400 (Code $_.Exception.Response) }
    }

    # A city-wide role sees the whole city, including the other operator.
    if ($bur) {
      $all = Invoke-RestMethod "$api/driver/trips" -Headers @{ Authorization = "Bearer $bur" } -TimeoutSec 10
      $allTrips = @($all.trips)
      Rep 'bureau sees every trip' 6 $allTrips.Count
      $foreign = @($allTrips | Where-Object { $_.vehiclePlate -eq 'ET-BB-2001' })[0]
      Rep 'foreign trip exists' 'True' ($null -ne $foreign)
      if ($foreign) {
        # The central scoping claim: the driver may not touch another operator's run.
        try { $null = Invoke-WebRequest "$api/driver/trips/$($foreign.id)/start" -Method Post -Headers $dh -TimeoutSec 10 -UseBasicParsing; Rep 'driver blocked on foreign trip' 403 200 } catch { Rep 'driver blocked on foreign trip' 403 (Code $_.Exception.Response) }
        try { $null = Invoke-WebRequest "$api/driver/trips/$($foreign.id)/manifest" -Headers $dh -TimeoutSec 10 -UseBasicParsing; Rep 'driver blocked on foreign manifest' 403 200 } catch { Rep 'driver blocked on foreign manifest' 403 (Code $_.Exception.Response) }
      }
    }
  }
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0
Add-Content -Path $out -Value 'DONE' -Encoding utf8