# End-to-end check of the agent cash sale.
#
# The claim being tested is that cash is not a second-class sale: it must travel
# the same fare re-derivation, the same payment orchestrator and the same I1
# issuance gate, and it must land in the shift so the drawer reconciles. A test
# that only asserts "a ticket came back" would pass even if the payment were
# written with no shift attached, so the last two steps are the real point —
# the reconciliation must actually see the money.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_cash.log"
$out = "$env:TEMP\addis_cash_report.txt"

function Rep($n, $e, $a) { Add-Content -Path $out -Value ('{0,-38} expected={1,-14} actual={2}' -f $n, $e, $a) -Encoding utf8 }
function Code($r) { try { [int]$r.StatusCode } catch { 0 } }
Set-Content -Path $out -Value ('CASH SALE ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8

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
      return Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = $phone; code = $all[$all.Count - 1].Groups[1].Value } | ConvertTo-Json)
    }
  }
  return $null
}

if ($up) {
  # ── The passenger plans a journey ─────────────────────────────────────────
  # A fresh, well-formed number per run. The OTP limit is time-windowed rather than
  # a counter that scripts/reset-otp-limits.sql can clear, so reusing one phone makes
  # every later run fail at sign-in for reasons unrelated to what is being tested.
  $passengerPhone = '+2517' + (Get-Random -Minimum 10000000 -Maximum 99999999)
  $pax = Otp $passengerPhone
  if ($pax -and $pax.accessToken) {
    $ph = @{ Authorization = "Bearer $($pax.accessToken)" }

      # /auth/verify-otp returns tokens only, so the user id must come
      # from /auth/me, which returns AuthenticatedUser ({ id, phone, displayName }).
      $me = Invoke-RestMethod "$api/auth/me" -Headers $ph -TimeoutSec 10
      $passengerUserId = $me.id
      Rep 'passenger id resolved' 'True' ($null -ne $passengerUserId)
    $stops = Invoke-RestMethod "$api/stops" -TimeoutSec 10
    $all = @($stops.stops)
    Rep 'stops available' 'True' ($all.Count -ge 2)

    # Two consecutive stops on route R-12, in sequence order. The planner only
    # connects stops that share a route in order, so pairing arbitrary stops is a
    # false negative. These ids are stable because the seed upserts stops by code.
    $origin = '4dcaa773-673b-40ab-b0d1-5b96a65f97c3'
    $dest = '0a52a809-e495-44ea-93b9-d22631cb790c'
    $fare = $null
    $journeyId = $null
    Rep 'route stops found' 'True' ($null -ne $origin)

    if ($origin) {
      try {
        # `/journeys/plan`, not `/stops/plan`: `plan` is declared on
        # JourneysController even though the file also holds StopsController. The
        # earlier "stops/plan 404" in this run was this test's mistake, not a
        # planner fault - the OpenAPI document confirms /api/v1/journeys/plan is
        # the real path.
        $p = Invoke-RestMethod "$api/journeys/plan" -Method Post -Headers $ph -ContentType 'application/json' -TimeoutSec 15 -Body (@{ originStopId = $origin; destinationStopId = $dest } | ConvertTo-Json)
        $opt = @($p.journeys) | Where-Object { $_.journeyId } | Select-Object -First 1
        if ($opt) { $journeyId = $opt.journeyId; $fare = $opt.totalFareFils }
      } catch { Rep 'plan call' 200 (Code $_.Exception.Response) }
    }
    Rep 'journey planned' 'True' ($null -ne $journeyId)
    Rep 'fare in fils' 'True' ($fare -gt 0)

    # ── The agent takes the cash ────────────────────────────────────────────
    # TICKET_OFFICER rather than AGENT. Both are in SHIFT_ROLES and can open a shift,
    # but the agent account has been OTP'd by earlier verification runs and the
    # limit is time-windowed, so reusing it fails at sign-in for reasons that have
    # nothing to do with what is being tested.
    $ag = Otp '+251911000008'
    Rep 'agent signs in' 'token' $(if ($ag -and $ag.accessToken) { 'token' } else { 'null' })

    if ($ag -and $ag.accessToken) {
      $ah = @{ Authorization = "Bearer $($ag.accessToken)" }
      $shift = Invoke-RestMethod "$api/staff/shifts/open" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 10 -Body (@{ openingCashFils = 2000 } | ConvertTo-Json)
      Rep 'shift opened' 'SFT-' ([string]$shift.reference).Substring(0, 4)

      # One key for BOTH calls in a run: the second is the idempotent replay, which only
        # returns the same ticket when the key is reused. Generating it per call would test
        # two separate sales instead and quietly pass.
        $saleKey = 'cash-' + [guid]::NewGuid().ToString('N').Substring(0, 12)


      try {
        $raw = Invoke-WebRequest "$api/staff/sales" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 20 -UseBasicParsing -Body (@{
            passengerUserId = $passengerUserId; journeyId = $journeyId; amountFils = $fare; idempotencyKey = $saleKey
          } | ConvertTo-Json)
        Rep 'sale http status' 200 $raw.StatusCode
        # The raw body is recorded verbatim: guessing at which field is missing is
        # how this test went wrong three times already.
        Rep 'sale body' '(diagnostic)' $raw.Content
        $sale = $raw.Content | ConvertFrom-Json
      } catch {
        # ErrorDetails.Message carries the response body for an HTTP error.
        # Reading the raw response stream instead returns an empty string,
        # because PowerShell has already consumed it by this point - which is how
        # the actual cause went missing from the first attempt at this diagnosis.
        $body = $_.ErrorDetails.Message
        if (-not $body) { $body = $_.Exception.Message }
        Rep 'sale http status' 200 (Code $_.Exception.Response)
        Rep 'sale error body' '(diagnostic)' $body
      }
      Rep 'cash sale confirmed' 'CONFIRMED' $sale.status
      Rep 'ticket issued' 'TKT-' ([string]$sale.ticket.reference).Substring(0, 4)
      Rep 'sale carries the shift' 'SFT-' ([string]$sale.shiftReference).Substring(0, 4)
      Rep 'ticket has a signed QR' 'True' ($sale.ticket.qrString.Length -gt 50)

      # Same idempotency key must converge on one payment, not two.
      $replay = Invoke-RestMethod "$api/staff/sales" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 20 -Body (@{
          passengerUserId = $passengerUserId; journeyId = $journeyId; amountFils = $fare; idempotencyKey = $saleKey
        } | ConvertTo-Json)
      Rep 'replay returns same ticket' ([string]$sale.ticket.ticketId) ([string]$replay.ticket.ticketId)

      # The decisive step: does the shift actually see the cash? If the payment
      # were written without a shiftId, expected would still be the opening float
      # and this would report a variance instead of balancing.
      $dec = Invoke-RestMethod "$api/staff/shifts/$($shift.id)/declare" -Method Post -Headers $ah -ContentType 'application/json' -TimeoutSec 15 -Body (@{ declaredCashFils = (2000 + $fare) } | ConvertTo-Json)
      Rep 'shift sees the cash' ([string]$fare) ([string]$dec.cashTakenDuringShiftFils)
      Rep 'shift balances' 'True' $dec.balanced
      Rep 'shift status' 'CLOSED' $dec.status
    }
  }
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0
Add-Content -Path $out -Value 'DONE' -Encoding utf8
