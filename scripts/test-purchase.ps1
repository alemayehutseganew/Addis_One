$base = 'http://127.0.0.1:3000/api/v1'
$log  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\server.log'
$out  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\purchase-test.txt'
$lines = @("=== purchase flow @ $(Get-Date -Format o) ===")

function Post-Json($path, $body, $token) {
  $h = @{ 'Content-Type' = 'application/json' }
  if ($token) { $h['Authorization'] = "Bearer $token" }
  try {
    Invoke-RestMethod -Uri "$base$path" -Method Post -Headers $h `
      -Body ($body | ConvertTo-Json -Compress -Depth 6) -TimeoutSec 25
  } catch { return @{ __error = $_.Exception.Message; __status = $_.Exception.Response.StatusCode.value__ } }
}
function Get-Json($path, $token) {
  $h = @{}
  if ($token) { $h['Authorization'] = "Bearer $token" }
  try {
    Invoke-RestMethod -Uri "$base$path" -Headers $h -TimeoutSec 25
  } catch { return @{ __error = $_.Exception.Message; __status = $_.Exception.Response.StatusCode.value__ } }
}

$phone = '+251911555444'
$lines += "--- sign in ($phone) ---"
$r = Post-Json '/auth/request-otp' @{ phone = $phone } $null
$lines += ('request_otp=' + ($r | ConvertTo-Json -Compress))
Start-Sleep -Seconds 1

$code = $null
if (Test-Path $log) {
  $pattern = '\[DEV OTP\] phone=' + [regex]::Escape($phone) + ' code=(\d{6})'
  $m = Select-String -Path $log -Pattern $pattern | Select-Object -Last 1
  if ($m -and $m.Matches.Count) { $code = $m.Matches[0].Groups[1].Value }
}
$lines += "code=$code"
if (-not $code) { $lines += 'FAILED: no code echoed'; Set-Content $out -Value $lines; exit 0 }

$v = Post-Json '/auth/verify-otp' @{ phone = $phone; code = $code } $null
$token = $v.accessToken
if (-not $token) { $lines += ('verify=' + ($v | ConvertTo-Json -Compress)); Set-Content $out -Value $lines; exit 0 }
$lines += "signed_in=True user=$($v.user.id.Substring(0,8))"

# ── Plan (this persists a Journey + FareCalculation for the user) ──────────
$all = Get-Json '/stops' $token
$piazza = ($all.stops | Where-Object { $_.code -eq 'PZA' })[0]
$bole   = ($all.stops | Where-Object { $_.code -eq 'BOR' })[0]
$lines += "--- plan $($piazza.name) -> $($bole.name) ---"
$plan = Post-Json '/journeys/plan' @{ originStopId = $piazza.id; destinationStopId = $bole.id } $token
if ($plan.__error) { $lines += "plan_error=$($plan.__error)"; Set-Content $out -Value $lines; exit 0 }
$lines += ("options=" + $plan.journeys.Count + " cheapest=" + $plan.journeys[0].totalFareFils + " saving=" + $plan.journeys[0].transferDiscountFils)

# ── Buy the persisted journey at its quoted fare ──────────────────────────
# Read the fare from the database rather than the response, so the test proves
# the SERVER stored the same number it quoted.
$js = @"
const { PrismaClient } = require('@prisma/client');
(async () => {
  const c = new PrismaClient();
  const u = await c.user.findFirst({ where: { phone: '$phone' } });
  const j = await c.journey.findFirst({
    where: { userId: u.id }, orderBy: { createdAt: 'desc' },
    include: { fareCalculation: true },
  });
  console.log('RESULT ' + JSON.stringify({
    journeyId: j.id, fare: j.fareCalculation.totalFareFils,
    ruleKey: j.fareCalculation.ruleKey, ruleVersion: j.fareCalculation.ruleVersion,
    transferDiscount: j.fareCalculation.transferDiscountFils,
  }));
  await c.`$disconnect();
})();
"@
$tmpJs = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\purchase-temp.js'
Set-Content -Path $tmpJs -Value $js -Encoding UTF8
$env:DATABASE_URL = $null
$raw = (& node.exe $tmpJs 2>&1 | Out-String)
Remove-Item $tmpJs -Force -EA SilentlyContinue
$line = ($raw -split "`n" | Where-Object { $_ -match 'RESULT ' } | Select-Object -First 1)
if (-not $line) { $lines += "db_read_error=$raw"; Set-Content $out -Value $lines; exit 0 }
$q = ($line -replace '.*RESULT ', '') | ConvertFrom-Json
$lines += "--- stored quote ---"
$lines += ("journeyId=" + $q.journeyId.Substring(0,8) + " fare=" + $q.fare +
           " rule=" + $q.ruleKey + " v" + $q.ruleVersion +
           " transferDiscount=" + $q.transferDiscount)

$lines += "--- POST /payments (exact fare) ---"
$key = [guid]::NewGuid().ToString()
$pay = Post-Json '/payments' @{
  journeyId = $q.journeyId; amountFils = $q.fare; method = 'TELEBIRR'; idempotencyKey = $key
} $token
if ($pay.__error) {
  $lines += "pay_error=$($pay.__error)"
} else {
  $lines += ("status=" + $pay.status + " providerMode=" + $pay.providerMode)
  $lines += ("replay=" + $pay.idempotentReplay)
  if ($pay.ticket) {
    $lines += ("ticket=" + $pay.ticket.reference)
    $lines += ("ticketFareRuleVersion=" + $pay.ticket.fareRuleVersion)
    $lines += ("qr=" + $pay.ticket.qrString.Substring(0, 100) + '...')
  } else {
    $lines += "ticket=NONE"
  }
}

$lines += "--- I2: replay same idempotency key ---"
$again = Post-Json '/payments' @{
  journeyId = $q.journeyId; amountFils = $q.fare; method = 'TELEBIRR'; idempotencyKey = $key
} $token
if ($again.__error) { $lines += "replay_error=$($again.__error)" }
else {
  $lines += ("samePayment=" + ($again.paymentId -eq $pay.paymentId))
  $lines += ("idempotentReplay=" + $again.idempotentReplay)
  $lines += ("sameTicket=" + ($again.ticket.reference -eq $pay.ticket.reference))
  $lines += ("sameQr=" + ($again.ticket.qrString -eq $pay.ticket.qrString))
}

$lines += "--- revenue protection: claim 1 fil ---"
$bad = Post-Json '/payments' @{
  journeyId = $q.journeyId; amountFils = 1; method = 'TELEBIRR'
  idempotencyKey = [guid]::NewGuid().ToString()
} $token
if ($bad.__error) { $lines += "tamper_rejected_status=$($bad.__status)" }
else { $lines += "FAIL: tampered payment ACCEPTED status=$($bad.status)" }

$lines += "--- I1: ticket for an unknown payment ---"
$nf = Get-Json '/payments/00000000-0000-0000-0000-000000000000/ticket' $token
$lines += "unknown_ticket_status=$($nf.__status)"

# ── GET /tickets/mine ──────────────────────────────────────────────────────
# The app's ticket list depends on this. It must return the ticket just bought
# and must not leak another passenger's.
$lines += "--- GET /tickets/mine ---"
$mine = Get-Json '/tickets/mine' $token
if ($mine.__error) {
  $lines += "mine_error=$($mine.__error)"
} else {
  $lines += "count=$($mine.tickets.Count)"
  foreach ($t in $mine.tickets) {
    $lines += ("  " + $t.reference + " status=" + $t.status +
               " mode=" + $t.mode + " ruleVersion=" + $t.fareRuleVersion +
               " hasQr=" + [bool]$t.qrString)
  }
  if ($mine.tickets.Count -gt 0) {
    $lines += ("  qrPrefix=" + $mine.tickets[0].qrString.Substring(0, 60) + '...')
  }
}

# ── Plan response carries the journeyId the app needs to buy ────────────────
$lines += "--- plan response shape ---"
$plan2 = Post-Json '/journeys/plan' @{
  originStopId = $piazza.id; destinationStopId = $bole.id
} $token
if ($plan2.__error) {
  $lines += "plan_error=$($plan2.__error)"
} else {
  $i = 0
  foreach ($it in $plan2.journeys) {
    $lines += ("  option" + $i + " journeyId=" + $(
      if ($it.journeyId) { $it.journeyId.Substring(0,8) } else { 'NULL' }
    ) + " seq0=" + $it.legs[0].sequence + " seq1=" + $it.legs[1].sequence)
    $i++
  }
  if ($plan2.journeys[0].journeyId) {
    $lines += "check: top option is purchasable"
  } else {
    $lines += "FAIL: top option has no journeyId, so the app cannot buy it"
  }
}

# ── Security: another passenger must not see these tickets ─────────────────
$lines += "--- cross-user isolation ---"
$other = '+251911000999'
Post-Json '/auth/request-otp' @{ phone = $other } $null | Out-Null
Start-Sleep -Seconds 1
$ocode = $null
if (Test-Path $log) {
  $op = '\[DEV OTP\] phone=' + [regex]::Escape($other) + ' code=(\d{6})'
  $om = Select-String -Path $log -Pattern $op | Select-Object -Last 1
  if ($om -and $om.Matches.Count) { $ocode = $om.Matches[0].Groups[1].Value }
}
if ($ocode) {
  $ov = Post-Json '/auth/verify-otp' @{ phone = $other; code = $ocode } $null
  $otherMine = Get-Json '/tickets/mine' $ov.accessToken
  $lines += ("other_user_ticket_count=" + $otherMine.tickets.Count)
  if ($otherMine.tickets.Count -ne 0) {
    $lines += "FAIL: a second passenger can see the first passenger's tickets"
  } else {
    $lines += "check: tickets are scoped to the authenticated user"
  }
} else {
  $lines += "cross_user_skipped=no second OTP issued"
}

Set-Content $out -Value $lines -Encoding UTF8
Write-Output 'done'
