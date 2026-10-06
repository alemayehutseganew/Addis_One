$base  = 'http://127.0.0.1:3000/api/v1'
$log   = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.log'
$out   = "$env:TEMP\addis_dash_api.txt"
$lines = @()
$lines += "=== dashboard api check @ $(Get-Date -Format o) ==="

function Get-Code($url, $headers) {
  try { Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 20 -UseBasicParsing | Out-Null; return 200 }
  catch { return [int]$_.Exception.Response.StatusCode }
}

# Signs in through the real OTP flow and returns a bearer header.
# The code is read from the server log because OTP_DEV_ECHO is on in dev; in
# production it would arrive by SMS and this helper would not exist.
function Sign-In($phone) {
  Invoke-RestMethod -Uri "$base/auth/request-otp" -Method Post -ContentType 'application/json' `
    -Body (@{ phone = $phone } | ConvertTo-Json -Compress) -TimeoutSec 20 | Out-Null
  Start-Sleep -Seconds 2
  $code = $null
  if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern 'code=(\d{6})' | Select-Object -Last 1
    if ($m -and $m.Matches.Count) { $code = $m.Matches[0].Groups[1].Value }
  }
  if (-not $code) { return $null }
  $s = Invoke-RestMethod -Uri "$base/auth/verify-otp" -Method Post -ContentType 'application/json' `
    -Body (@{ phone = $phone; code = $code } | ConvertTo-Json -Compress) -TimeoutSec 20
  return @{ Authorization = "Bearer $($s.accessToken)" }
}

# 1. Health
try {
  $h = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 20
  $lines += "health=" + ($h | ConvertTo-Json -Compress)
} catch { $lines += "health_error=" + $_.Exception.Message }

# 2. Unauthenticated access must be refused
$lines += "unauth_overview_status=" + (Get-Code "$base/dashboard/overview" @{})

# 3. Sign in as the bureau administrator
$auth = Sign-In '+251911000001'
$lines += "signed_in=$([bool]$auth)"

# 4. Session
$lines += '--- session ---'
try {
  $sess = Invoke-RestMethod -Uri "$base/dashboard/session" -Headers $auth -TimeoutSec 20
  $lines += ($sess | ConvertTo-Json -Compress -Depth 5)
} catch { $lines += 'session_error=' + $_.Exception.Message }

# 5. Every endpoint, with status codes
foreach ($p in @('overview', 'operations', 'network', 'fares', 'passengers', 'revenue')) {
  $lines += "GET /dashboard/$p -> " + (Get-Code "$base/dashboard/$p" $auth)
}

# 6. Overview payload
$lines += '--- overview ---'
try {
  $o = Invoke-RestMethod -Uri "$base/dashboard/overview" -Headers $auth -TimeoutSec 30
  $lines += ('kpis=' + ($o.kpis | ConvertTo-Json -Compress))
  $lines += ('scope=' + ($o.scope | ConvertTo-Json -Compress))
  $lines += ('network=' + ($o.network | ConvertTo-Json -Compress))
  $lines += ('passengers=' + ($o.passengers | ConvertTo-Json -Compress))
  $lines += ('revenue_series_days=' + $o.series.revenue.Count)
  $lines += ('revenue_series_sum=' + (($o.series.revenue | Measure-Object -Property revenueFils -Sum).Sum))
  $lines += ('journey_series_days=' + $o.series.journeys.Count)
} catch { $lines += 'overview_error=' + $_.Exception.Message }


# 7. Revenue, cross-checked against its own status breakdown
$lines += '--- revenue ---'
try {
  $r = Invoke-RestMethod -Uri "$base/dashboard/revenue?pageSize=5" -Headers $auth -TimeoutSec 20
  $lines += ('totals=' + ($r.totals | ConvertTo-Json -Compress))
  $lines += ('byStatus=' + ($r.byStatus | ConvertTo-Json -Compress))
  $lines += ('byMethod=' + ($r.byMethod | ConvertTo-Json -Compress))
  $lines += ("rows=$($r.payments.Count) total=$($r.total)")
  # The headline confirmed total must equal the CONFIRMED row of the breakdown.
  # These are computed by different queries, so a mismatch means one is wrong.
  $fromStatus = ($r.byStatus | Where-Object { $_.status -eq 'CONFIRMED' } | Measure-Object -Property amountFils -Sum).Sum
  if ($null -eq $fromStatus) { $fromStatus = 0 }
  $lines += "confirmed_totals=$($r.totals.confirmedFils) confirmed_bystatus=$fromStatus match=$($r.totals.confirmedFils -eq $fromStatus)"
} catch { $lines += 'revenue_error=' + $_.Exception.Message }

# 8. Fares: I3 requires both CITY-BUS versions to be visible
$lines += '--- fares ---'
try {
  $f = Invoke-RestMethod -Uri "$base/dashboard/fares" -Headers $auth -TimeoutSec 20
  $lines += ('totals=' + ($f.totals | ConvertTo-Json -Compress))
  $city = $f.groups | Where-Object { $_.ruleKey -eq 'CITY-BUS' }
  $vlist = ($city.versions | ForEach-Object { "v$($_.version):$($_.status)" }) -join ','
  $lines += "CITY-BUS activeVersion=$($city.activeVersion) versions=$vlist"
} catch { $lines += 'fares_error=' + $_.Exception.Message }

# 9. Invalid input must be a 400, never a 500 and never a silent full scan
$lines += '--- validation ---'
$lines += "bad_from_status="          + (Get-Code "$base/dashboard/overview?from=not-a-date" $auth)
$lines += "huge_range_status="        + (Get-Code "$base/dashboard/overview?from=2000-01-01&to=2026-01-01" $auth)
$lines += "inverted_range_status="    + (Get-Code "$base/dashboard/overview?from=2026-06-01&to=2026-01-01" $auth)
$lines += "bad_status_filter="        + (Get-Code "$base/dashboard/revenue?status=NOPE" $auth)
$lines += "pageSize_huge_status="     + (Get-Code "$base/dashboard/revenue?pageSize=99999" $auth)
$lines += "page_zero_status="         + (Get-Code "$base/dashboard/revenue?page=0" $auth)

# 10. A citizen token is valid for the API but must not reach the dashboard
$lines += '--- citizen must be refused ---'
try {
  $cauth = Sign-In '+251911234567'
  $lines += "citizen_overview_status=" + (Get-Code "$base/dashboard/overview" $cauth)
  $lines += "citizen_revenue_status=" + (Get-Code "$base/dashboard/revenue" $cauth)
  $lines += "citizen_network_status="  + (Get-Code "$base/dashboard/network" $cauth)
  # Control: the same token must still work on a normal authenticated route,
  # proving the 403 above is about staff status and not a broken token.
  $lines += "citizen_auth_me_status=" + (Get-Code "$base/auth/me" $cauth)
} catch { $lines += 'citizen_error=' + $_.Exception.Message }

# 11. Operator scoping: an OPERATOR_ADMIN sees a narrower network than the bureau
$lines += '--- operator scoping ---'
try {
  $oauth = Sign-In '+251911000003'
  $osess = Invoke-RestMethod -Uri "$base/dashboard/session" -Headers $oauth -TimeoutSec 20
  $lines += ('operator_session=' + ($osess | ConvertTo-Json -Compress -Depth 5))
  $on = Invoke-RestMethod -Uri "$base/dashboard/network" -Headers $oauth -TimeoutSec 20
  $lines += ('operator_network=' + ($on | ConvertTo-Json -Compress))
} catch { $lines += 'operator_error=' + $_.Exception.Message }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output 'done'
