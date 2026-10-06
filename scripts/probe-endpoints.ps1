param([string]$ApiBaseUrl = 'http://127.0.0.1:3000/api/v1')

# Probes the four endpoints whose auth boundary actually matters, WITHOUT an
# auth header. That is the point: a guard that should be public and silently
# became private (or the reverse) is invisible to a signed-in test and shows up
# in production as "the app says sign in to view a fare".
#
# Each probe declares the status a correct build must return, so a mismatch
# names itself instead of needing interpretation.

$out = "$env:TEMP\addis_probe.txt"
$probes = @(
  @{ Path = '/health';        Expect = 200; Note = 'liveness + database reachability' },
  @{ Path = '/stops?q=bole';  Expect = 200; Note = 'PUBLIC: browse the network before signup' },
  @{ Path = '/journeys/mine'; Expect = 200; Note = 'PUBLIC: anonymous gets signedIn:false' },
  @{ Path = '/tickets/mine';  Expect = 401; Note = 'PRIVATE: must reject an anonymous caller' }
)

$lines = @("=== probe @ $(Get-Date -Format o) ===", "base=$ApiBaseUrl", '')
$failed = 0

foreach ($p in $probes) {
  $url = "$ApiBaseUrl$($p.Path)"
  $body = ''
  try {
    $res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
    $code = $res.StatusCode
    $body = $res.Content
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    $body = $_.ErrorDetails.Message
    if (-not $code) { $code = "ERR" }
  }
  $ok = ($code -eq $p.Expect)
  if (-not $ok) { $failed++ }
  $lines += "[$([string]($(if($ok){'PASS'}else{'FAIL'})))] $code expected=$($p.Expect) $($p.Path)"
  $lines += "        $($p.Note)"
  if (-not $ok -and $body) {
    $snippet = if ($body.Length -gt 200) { $body.Substring(0,200) } else { $body }
    $lines += "        body: $snippet"
  }
}

$lines += ''
$lines += if ($failed -eq 0) { 'RESULT: all probes matched expectation' }
            else { "RESULT: $failed probe(s) wrong" }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
