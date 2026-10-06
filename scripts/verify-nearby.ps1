param()

# Exercises GET /stops/nearby against the running server and a live database.
#
# Probes a real Addis coordinate and checks the ranking is actually correct:
# the first result must be the stop with the smallest distance, the distances
# must come back ascending, and they must be plausible for a city. A zeroed
# coordinate is included deliberately, because Number('') is 0 and a missing
# parameter must be rejected rather than silently read as the Gulf of Guinea.

$ErrorActionPreference = 'Stop'
$out = "$env:TEMP\addis_nearby.txt"
$base = 'http://127.0.0.1:3000/api/v1'
# `$lines` is appended to from inside Probe, so it must be script-scoped. A plain
# `$lines += ...` inside a function would write to a function-local copy and the
# result would vanish, leaving the report silently shorter than the checks run.
$script:lines = @("=== /stops/nearby @ $(Get-Date -Format o) ===")

function Probe($label, $url, $expect) {
  try {
    $res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
    $code = $res.StatusCode
    $body = $res.Content
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    $body = $_.ErrorDetails.Message
    if (-not $code) { $code = 'ERR' }
  }
  $ok = if ($code -eq $expect) { 'PASS' } else { 'FAIL' }
  $script:lines += "[$ok] $code expected=$expect  $label"
  return @{ code = $code; body = $body }
}

# Arat Kilo is in central Addis; expect real stops a few hundred metres away.
$r = Probe 'real coordinate' "$base/stops/nearby?lat=9.0192&lng=38.7525&limit=5" 200
if ($r.code -eq 200) {
  $json = $r.body | ConvertFrom-Json
  $stops = $json.stops
  $lines += "  returned $($stops.Count) stops"
  foreach ($s in $stops) {
    $lines += ("  {0,-28} {1,6} m  ({2}, {3})" -f $s.name, $s.distanceMeters, $s.latitude, $s.longitude)
  }
  if ($stops.Count -gt 0) {
    $first = $stops[0].distanceMeters
    $lines += "  nearest = $($stops[0].name) at ${first}m"

    # The whole point of the endpoint: ordering by real distance.
    $ascending = $true
    for ($i = 1; $i -lt $stops.Count; $i++) {
      if ($stops[$i].distanceMeters -lt $stops[$i - 1].distanceMeters) { $ascending = $false }
    }
    $lines += "  $(if ($ascending) { 'PASS' } else { 'FAIL' }) ordered nearest-first"

    # A city bus stop within a few km of the centre; 0 would mean the query is
    # silently returning something unrelated to the coordinate.
    $plausible = $first -gt 0 -and $first -lt 20000
    $lines += "  $(if ($plausible) { 'PASS' } else { 'FAIL' }) nearest distance is plausible for Addis (got ${first}m)"
  } else {
    $lines += '  FAIL returned no stops'
  }
}

Probe 'missing lat' "$base/stops/nearby?lng=38.75" 400 | Out-Null
Probe 'empty lat' "$base/stops/nearby?lat=&lng=38.75" 400 | Out-Null
Probe 'lat out of range' "$base/stops/nearby?lat=91&lng=38.75" 400 | Out-Null
Probe 'lng out of range' "$base/stops/nearby?lat=9&lng=181" 400 | Out-Null
Probe 'no params at all' "$base/stops/nearby" 400 | Out-Null

# The clamp: asking for 9999 must not dump the whole network.
$clamped = Probe 'limit clamped' "$base/stops/nearby?lat=9.0192&lng=38.7525&limit=9999" 200
if ($clamped.code -eq 200) {
  $count = (($clamped.body | ConvertFrom-Json).stops).Count
  $script:lines += "  $(if ($count -le 10) { 'PASS' } else { 'FAIL' }) clamped to at most 10 (got $count)"
}

# The radius. This is the check that would have caught the original bug: a point
# outside Addis Ababa used to resolve to the globally nearest stop, and the app
# displayed "Bole, 4,253,742 m" as the passenger's origin.
$far = Probe 'outside the service area' "$base/stops/nearby?lat=12.9716&lng=77.5946&limit=5" 200
if ($far.code -eq 200) {
  $body = $far.body | ConvertFrom-Json
  $farCount = @($body.stops).Count
  $script:lines += "  $(if ($farCount -eq 0) { 'PASS' } else { 'FAIL' }) Delhi returns no stops (got $farCount)"
  $script:lines += "  $(if ($body.radiusMeters -eq 2000) { 'PASS' } else { 'FAIL' }) radius echoed to the client (got $($body.radiusMeters))"
}

# A stop just inside the radius must still be returned, or the check above would
# pass on a query that is broken for every input.
$edge = Probe 'inside the radius' "$base/stops/nearby?lat=9.0192&lng=38.7525&limit=5&radiusMeters=5000" 200
if ($edge.code -eq 200) {
  $edgeCount = @((($edge.body | ConvertFrom-Json).stops)).Count
  $script:lines += "  $(if ($edgeCount -gt 0) { 'PASS' } else { 'FAIL' }) a real Addis point still resolves (got $edgeCount)"
}

Set-Content -Path $out -Value $script:lines -Encoding UTF8
Write-Output "wrote $out"