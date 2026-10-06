param([int]$WaitSeconds = 12)

# Boots the backend, then probes the four endpoints that matter, writing results
# to $env:TEMP\addis_be_verify.txt.
#
# The probes deliberately run UNAUTHENTICATED, because the regression being
# guarded is exactly that: a guard that was meant to be public silently became
# private (or vice versa), and it only shows up as a status code.

Set-Location 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$out = "$env:TEMP\addis_be_verify.txt"

$lines = @()
$lines += & powershell -ExecutionPolicy Bypass -File .\scripts\start-backend.ps1 2>&1
$lines += '--- waiting for boot ---'
Start-Sleep -Seconds $WaitSeconds

# Expectation per endpoint. `$expect` is what a correct build must return, so a
# mismatch names itself rather than needing interpretation.
$probes = @(
  @{ Url = 'http://127.0.0.1:3000/api/v1/health';       Expect = 200; Note = 'liveness + database' },
  @{ Url = 'http://127.0.0.1:3000/api/v1/stops?q=bole';  Expect = 200; Note = 'public: browse before signup' },
  @{ Url = 'http://127.0.0.1:3000/api/v1/journeys/mine'; Expect = 200; Note = 'public: anonymous = signedIn:false' },
  @{ Url = 'http://127.0.0.1:3000/api/v1/tickets/mine';  Expect = 401; Note = 'PRIVATE: must stay 401' }
)

$lines += '--- probes (no auth header) ---'
$failed = 0
foreach ($p in $probes) {
  try {
    $res = Invoke-WebRequest -Uri $p.Url -TimeoutSec 8 -UseBasicParsing
    $code = $res.StatusCode
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if (-not $code) { $code = "ERR $($_.Exception.Message)" }
  }
  $ok = if ($code -eq $p.Expect) { 'PASS' } else { $failed++ ; 'FAIL' }
  $lines += "[$ok] $code (expected $($p.Expect))  $($p.Url)  - $($p.Note)"
  if ($ok -eq 'FAIL') { $lines += "       body: $($_.ErrorDetails.Message)" }
}

$lines += '--- result ---'
if ($failed -eq 0) { $lines += 'all probes matched expectation' }
else { $lines += "$failed probe(s) did NOT match expectation" }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
