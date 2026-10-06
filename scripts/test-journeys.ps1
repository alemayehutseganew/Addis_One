$base = 'http://127.0.0.1:3000/api/v1'
$log  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.log'
$out  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\journey-test.txt'
$lines = @()
$lines += "=== journey flow test @ $(Get-Date -Format o) ==="

function Post-Json($path, $body, $token) {
  $h = @{ 'Content-Type' = 'application/json' }
  if ($token) { $h['Authorization'] = "Bearer $token" }
  try {
    Invoke-RestMethod -Uri "$base$path" -Method Post -Headers $h `
      -Body ($body | ConvertTo-Json -Compress -Depth 6) -TimeoutSec 25
  } catch { return @{ __error = $_.Exception.Message } }
}
function Get-Json($path, $token) {
  $h = @{}
  if ($token) { $h['Authorization'] = "Bearer $token" }
  try {
    Invoke-RestMethod -Uri "$base$path" -Headers $h -TimeoutSec 25
  } catch { return @{ __error = $_.Exception.Message } }
}

# ── Authenticate so the guarded endpoints accept us ─────────────────────────
$phone = '+251911000777'
$lines += "--- sign in ($phone) ---"
$r = Post-Json '/auth/request-otp' @{ phone = $phone } $null
$lines += ('request_otp=' + ($r | ConvertTo-Json -Compress))

Start-Sleep -Seconds 1
$code = $null
if (Test-Path $log) {
  # The phone contains '+', which is a regex quantifier — it must be escaped or
  # `phone=+251...` matches nothing at all.
  $pattern = '\[DEV OTP\] phone=' + [regex]::Escape($phone) + ' code=(\d{6})'
  $m = Select-String -Path $log -Pattern $pattern | Select-Object -Last 1
  if ($m -and $m.Matches.Count) { $code = $m.Matches[0].Groups[1].Value }
}
$lines += "code=$code"
if (-not $code) {
  $lines += 'FAILED: no code echoed'
  Set-Content $out -Value $lines -Encoding UTF8
  Write-Output 'done(failed)'; exit 0
}

$v = Post-Json '/auth/verify-otp' @{ phone = $phone; code = $code } $null
$token = $v.accessToken
$lines += ('signed_in=' + [bool]$token)
if (-not $token) {
  $lines += ('verify=' + ($v | ConvertTo-Json -Compress))
  Set-Content $out -Value $lines -Encoding UTF8
  Write-Output 'done(failed)'; exit 0
}

# ── Search ────────────────────────────────────────────────────────────────
$lines += "--- GET /stops?q=bole ---"
$s = Get-Json '/stops?q=bole' $token
$lines += ('found=' + $s.stops.Count + ' first=' + $s.stops[0].name + '/' + $s.stops[0].nameAm)

$lines += "--- GET /stops?q=merk ---"
$s2 = Get-Json '/stops?q=merk' $token
$lines += ('found=' + $s2.stops.Count + ' name=' + $s2.stops[0].name)

# ── Plan a real journey: Piazza -> Bole ────────────────────────────────────
$all = Get-Json '/stops' $token
$piazza = ($all.stops | Where-Object { $_.code -eq 'PZA' })[0]
$bole   = ($all.stops | Where-Object { $_.code -eq 'BOR' })[0]
$lines += "--- POST /journeys/plan  $($piazza.name) -> $($bole.name) ---"
$j = Post-Json '/journeys/plan' @{ originStopId = $piazza.id; destinationStopId = $bole.id } $token

if ($j.__error) {
  $lines += "plan_error=" + $j.__error
} else {
  $lines += ("journeys=" + $j.journeys.Count)
  foreach ($it in $j.journeys) {
    $routeNames = ($it.legs | ForEach-Object { $_.routeCode }) -join ' + '
    $lines += ("  id=" + $it.id +
               " legs=" + $routeNames +
               " fare=" + $it.totalFareFils +
               " discount=" + $it.transferDiscountFils +
               " dur=" + $it.totalDurationSeconds + "s" +
               " transfers=" + $it.transferCount +
               " freshness=" + $it.freshness)
    # Legs must be individually priced and correctly ordered, otherwise a
    # passenger cannot tell what they are paying for on each bus.
    foreach ($l in $it.legs) {
      $lines += ("      seq=" + $l.sequence + " " + $l.routeCode +
                 " " + $l.fromLabel + " -> " + $l.toLabel +
                 " fare=" + $l.fareFils)
    }
  }

  # The per-leg fares shown to the passenger must be the fares actually
  # charged, so the legs have to sum to the total. The saving is what the
  # second leg WOULD have cost at full fare, which is what the bureau reports.
  foreach ($it in $j.journeys) {
    if ($it.transferCount -gt 0) {
      $sum = ($it.legs | Measure-Object -Property fareFils -Sum).Sum
      if ($sum -ne $it.totalFareFils) {
        $lines += ("FAIL: legs sum to $sum but total is " + $it.totalFareFils)
      } else {
        $lines += ("check: legs sum to total (" + $sum + "), saving=" +
                   $it.transferDiscountFils)
      }
      if ($it.transferDiscountFils -le 0) {
        $lines += "FAIL: transfer journey reports no saving"
      }
    } else {
      if ($it.transferDiscountFils -ne 0) {
        $lines += "FAIL: direct journey must not report a saving"
      }
    }
  }
}

Set-Content $out -Value $lines -Encoding UTF8
Write-Output 'done'
