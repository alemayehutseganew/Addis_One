# Live check of the identity (shifts/devices), mobility (driver trips) and
# assurance (complaints) modules.
#
# Kept short on purpose: the sandbox tears down a foreground command after about a
# minute, so this does the fewest round-trips that still prove the interesting
# behaviour — the refusals, not just the happy paths.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_staff.log"
$out = "$env:TEMP\addis_staff_report.txt"

function Rep($n, $e, $a) { Add-Content -Path $out -Value ('{0,-36} expected={1,-14} actual={2}' -f $n, $e, $a) -Encoding utf8 }
function Code($resp) { try { [int]$resp.StatusCode } catch { 0 } }
Set-Content -Path $out -Value ('STAFF MODULES ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8

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
    # Take the LAST code, not the first. The log is cumulative, so matching from
    # the start silently re-used the previous sign-in's code for every subsequent
    # user and the second sign-in appeared to fail for no visible reason.
    $all = [regex]::Matches($p, 'code[=\s:]+(\d{6})')
    if ($all.Count -gt 0) {
      $code = $all[$all.Count - 1].Groups[1].Value
      return (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = $phone; code = $code } | ConvertTo-Json)).accessToken
    }
  }
  return $null
}

if ($up) {
  $agent = Otp '+251911000011'
  $bureau = Otp '+251911000001'
  Rep 'agent signs in' 'token' $(if ($agent) { 'token' } else { 'null' })
  Rep 'bureau signs in' 'token' $(if ($bureau) { 'token' } else { 'null' })

  # ── Identity: shifts ──────────────────────────────────────────────────────
  if ($agent) {
    $ah = @{ Authorization = "Bearer $agent" }
    try {
      $s = Invoke-RestMethod "$api/staff/shifts/open" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 10 -Body (@{ openingCashFils = 5000 } | ConvertTo-Json)
      Rep 'agent opens shift' 'SFT-' ([string]$s.reference).Substring(0, 4)
      Rep 'opening cash recorded' 5000 $s.openingCashFils
      # A second concurrent shift would make "the cash in this shift" ambiguous.
      try { $null = Invoke-WebRequest "$api/staff/shifts/open" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 10 -Body (@{ openingCashFils = 1 } | ConvertTo-Json) -UseBasicParsing; Rep 'second shift refused' 400 200 } catch { Rep 'second shift refused' 400 (Code $_.Exception.Response) }
      # Declaring a figure that does not match must be caught, not accepted.
      try { $d = Invoke-RestMethod "$api/staff/shifts/$($s.id)/declare" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 10 -Body (@{ declaredCashFils = 4000 } | ConvertTo-Json); Rep 'cash variance detected' 'False' $d.balanced; Rep 'variance in fils' -1000 $d.varianceFils; Rep 'variance status' 'RECONCILING' $d.status } catch { Rep 'cash variance detected' 'False' (Code $_.Exception.Response) }
    } catch { Rep 'agent opens shift' 'SFT-' (Code $_.Exception.Response) }
  }

  # A city-wide role holds no cash, so opening a shift under one must be refused.
  if ($bureau) {
    try { $null = Invoke-WebRequest "$api/staff/shifts/open" -Method Post -Headers @{ Authorization = "Bearer $bureau" } -ContentType 'application/json' -TimeoutSec 10 -Body (@{ openingCashFils = 0 } | ConvertTo-Json) -UseBasicParsing; Rep 'bureau cannot open shift' 403 200 } catch { Rep 'bureau cannot open shift' 403 (Code $_.Exception.Response) }
  }

  # ── Assurance: complaints ─────────────────────────────────────────────────
  try {
    $c = Invoke-RestMethod "$api/complaints" -Method Post -ContentType 'application/json' -TimeoutSec 10 -Body (@{ category = 'SAFETY'; description = 'Bus braking was very abrupt on the last trip.' } | ConvertTo-Json)
    Rep 'anonymous can file complaint' 'CMP-' ([string]$c.reference).Substring(0, 4)
    # SAFETY must be escalated above the default priority.
    Rep 'safety complaint escalated' 1 $c.priority
    # Staff queue: anonymous callers must not reach it.
    # JwtAuthGuard rejects an anonymous caller before StaffGuard is ever consulted, so
    # the correct status is 401, not 403. Asserting 403 would have "caught" a
    # difference in guard ordering that is in fact correct behaviour.
    try { $null = Invoke-WebRequest "$api/complaints" -TimeoutSec 10 -UseBasicParsing; Rep 'queue hidden from anonymous' 401 200 } catch { Rep 'queue hidden from anonymous' 401 (Code $_.Exception.Response) }
    if ($bureau) {
      $q = Invoke-RestMethod "$api/complaints" -Headers @{ Authorization = "Bearer $bureau" } -TimeoutSec 10
      # Wrapped in @() because Invoke-RestMethod unwraps a single-element JSON
      # array to a bare object, and a bare object's .Count is $null in PS 5.1 —
      # which reads as "queue is empty" when it merely held one item.
      Rep 'bureau reads queue' 'True' (@($q.complaints).Count -ge 1)
      # Resolving with no written resolution must be refused.
      try { $null = Invoke-WebRequest "$api/complaints/$($c.reference)" -Method Patch -Headers @{ Authorization = "Bearer $bureau" } -ContentType 'application/json' -TimeoutSec 10 -Body (@{ status = 'RESOLVED' } | ConvertTo-Json) -UseBasicParsing; Rep 'resolve needs a reason' 400 200 } catch { Rep 'resolve needs a reason' 400 (Code $_.Exception.Response) }
      # Nor may a complaint be resolved straight from OPEN: it has to be
      # investigated first, so the jump is refused even with a resolution.
      try { $null = Invoke-WebRequest "$api/complaints/$($c.reference)" -Method Patch -Headers @{ Authorization = "Bearer $bureau" } -ContentType 'application/json' -TimeoutSec 10 -Body (@{ status = 'RESOLVED'; resolution = 'Driver briefed.' } | ConvertTo-Json) -UseBasicParsing; Rep 'cannot skip investigation' 400 200 } catch { Rep 'cannot skip investigation' 400 (Code $_.Exception.Response) }
      $null = Invoke-RestMethod "$api/complaints/$($c.reference)" -Method Patch -Headers @{ Authorization = "Bearer $bureau" } -ContentType 'application/json' -TimeoutSec 10 -Body (@{ status = 'INVESTIGATING' } | ConvertTo-Json)
      $r = Invoke-RestMethod "$api/complaints/$($c.reference)" -Method Patch -Headers @{ Authorization = "Bearer $bureau" } -ContentType 'application/json' -TimeoutSec 10 -Body (@{ status = 'RESOLVED'; resolution = 'Driver briefed and vehicle inspected.' } | ConvertTo-Json)
      Rep 'complaint resolved' 'RESOLVED' $r.status
    }
  } catch { Rep 'anonymous can file complaint' 'CMP-' (Code $_.Exception.Response) }
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0
Add-Content -Path $out -Value 'DONE' -Encoding utf8