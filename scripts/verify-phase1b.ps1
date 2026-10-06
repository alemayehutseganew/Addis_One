# Phase 1 live gate: config validation, Swagger mount, dashboard, and admin CRUD
# still working after the controller rewiring.
#
# Deliberately fast and incremental. This sandbox kills a command's process tree
# after roughly a minute, so a script that runs `prisma validate` (~30s) before
# booting the server never gets to write its report. Every check therefore
# appends to the report immediately, so partial progress survives a kill, and the
# slow Prisma CLI work is left to its own command.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_phase1.log"
$out = "$env:TEMP\addis_phase1_report.txt"

function Add-Rep($name, $expected, $actual) {
  $line = ('{0,-34} expected={1,-12} actual={2}' -f $name, $expected, $actual)
  Add-Content -Path $out -Value $line -Encoding utf8
}

Set-Content -Path $out -Value ("PHASE 1 LIVE GATE " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding utf8

# The stale value that caused the P1012 outage. User/Machine scope are already
# cleared; the inherited process value still has to go or every child process
# (npm, prisma, node) keeps seeing it.
$env:DATABASE_URL = $null
Add-Rep 'process DATABASE_URL' '(empty)' $env:DATABASE_URL

Set-Location $base

# The config validator is checked here with the compiled build rather than Jest.
# Jest is unusable inside this sandbox: it dies with 0xC0000139 (Windows worker
# spawn) and a rerun leaves an empty log, which then stalls the rest of the gate.
# `scripts/check-validate-env.js` runs in about a second against dist/. The same
# assertions live in backend/src/config/validate-env.spec.ts for CI.
$envLog = cmd /c "node ..\scripts\check-validate-env.js 2>&1"
Add-Rep 'config validator (compiled)' 'ALL PASSED' (($envLog | Out-String).Trim() -split "`r?`n" | Select-Object -Last 1).Trim()

# ── Live boot ───────────────────────────────────────────────────────────────
Remove-Item $log -EA 0
$job = Start-Job -ScriptBlock {
  param($dir, $outFile)
  Set-Location $dir
  $env:DATABASE_URL = $null
  $env:OTP_DEV_ECHO = 'true'
  node dist/main.js *> $outFile
} -ArgumentList $base, $log

$up = $false
1..18 | ForEach-Object {
  if (-not $up) {
    Start-Sleep -Seconds 2
    try {
      if ((Invoke-WebRequest "$api/health" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { $up = $true }
    } catch { }
  }
}
Add-Rep 'server boots' 200 $(if ($up) { 200 } else { 0 })

if ($up) {
  # Swagger: the dependency was present but unmounted, so this is new surface.
  foreach ($p in @(@{ u = '/api/docs-json'; n = 'openapi json' }, @{ u = '/api/docs'; n = 'swagger ui' })) {
    try {
      $r = Invoke-WebRequest ('http://127.0.0.1:3000' + $p.u) -TimeoutSec 10 -UseBasicParsing
      Add-Rep $p.n 200 $r.StatusCode
      if ($p.n -eq 'openapi json') {
        $j = $r.Content | ConvertFrom-Json
        Add-Rep 'openapi bearer scheme' 'True' ($null -ne $j.components.securitySchemes)
        # The path names have to be compared as a list. `$j.paths.$need` cannot
        # work when $need contains slashes - PowerShell takes the entire string as
        # a single property name, so every lookup returned null and the gate
        # reported four routes as absent when they were in the document.
        $names = @($j.paths.PSObject.Properties.Name)
        Add-Rep 'openapi path count' '>20' $names.Count
        Add-Rep 'openapi sample paths' '(diagnosis)' (($names | Select-Object -First 5) -join ' ')
        # With a global prefix set, Swagger records the full public path, so the
        # document carries /api/v1/... rather than the controller-local route.
        # `plan` lives on JourneysController, not StopsController - both classes
        # are declared in journeys.controller.ts, which is exactly the kind of
        # thing this document exists to settle.
        foreach ($need in @('/api/v1/auth/verify-otp', '/api/v1/admin/stops', '/api/v1/tickets/mine', '/api/v1/dashboard/overview', '/api/v1/journeys/plan')) {
          Add-Rep "openapi has $need" 'True' ($names -contains $need)
        }
      }
    } catch { Add-Rep $p.n 200 ('ERR ' + $_.Exception.Message) }
  }

  try { $d = Invoke-WebRequest 'http://127.0.0.1:3000/dashboard/' -TimeoutSec 10 -UseBasicParsing; Add-Rep 'dashboard page' 200 $d.StatusCode } catch { Add-Rep 'dashboard page' 200 ('ERR ' + $_.Exception.Message) }

  $null = Invoke-RestMethod "$api/auth/request-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000001' } | ConvertTo-Json)
  $code = $null
  1..12 | ForEach-Object {
    if (-not $code) {
      Start-Sleep -Milliseconds 300
      # Nest colourises its logger output, so the escape sequences have to come
      # out before the pattern is matched - otherwise `code` and its digits are
      # separated by a control sequence and no single regex matches both. The
      # separator is `=` (not `:`), which is why an earlier `code[:\s]+(\d{6})`
      # pattern silently found nothing and reported the OTP as never issued.
      $plain = (Get-Content $log -Raw -EA 0) -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
      $m = [regex]::Match($plain, 'code[=\s:]+(\d{6})')
      if ($m.Success) { $code = $m.Groups[1].Value }
    }
  }
  Add-Rep 'otp issued for seeded bureau' '6-digit' $(if ($code) { '6-digit' } else { 'none' })

  if ($code) {
    $t = (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000001'; code = $code } | ConvertTo-Json)).accessToken
    Add-Rep 'bureau signs in' 'token' $(if ($t) { 'token' } else { 'null' })
    if ($t) {
      $h = @{ Authorization = "Bearer $t" }
      try { $s = Invoke-RestMethod "$api/dashboard/session" -Headers $h -TimeoutSec 10; Add-Rep 'session canManage' 'True' $s.permissions.canManage; Add-Rep 'session canViewDatabase' 'True' $s.permissions.canViewDatabase } catch { Add-Rep 'session canManage' 'True' ('ERR ' + $_.Exception.Message) }
      foreach ($r in @('operators', 'stops', 'routes', 'vehicles', 'fare-rules', 'staff')) {
        try { $x = Invoke-WebRequest "$api/admin/$r" -Headers $h -TimeoutSec 10 -UseBasicParsing; Add-Rep "GET /admin/$r" 200 $x.StatusCode } catch { Add-Rep "GET /admin/$r" 200 ('ERR ' + $_.Exception.Message) }
      }
    }
  }
# ── Ticket validation (the inspector's scanner) ────────────────────────────
  # Signed in as the seeded INSPECTOR, not as the bureau admin: the role gate is
  # the thing under test, and an admin token would satisfy it regardless.
  $null = Invoke-RestMethod "$api/auth/request-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000009' } | ConvertTo-Json)
  $icode = $null
  1..12 | ForEach-Object {
    if (-not $icode) {
      Start-Sleep -Milliseconds 300
      $plain2 = (Get-Content $log -Raw -EA 0) -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
      $m2 = [regex]::Match($plain2, 'code[=\s:]+(\d{6})')
      if ($m2.Success) { $icode = $m2.Groups[1].Value }
    }
  }
  Add-Rep 'inspector otp issued' '6-digit' $(if ($icode) { '6-digit' } else { 'none' })

  if ($icode) {
    $it = (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000009'; code = $icode } | ConvertTo-Json)).accessToken
    Add-Rep 'inspector signs in' 'token' $(if ($it) { 'token' } else { 'null' })

    # No token at all.
    try { $null = Invoke-WebRequest "$api/validation/clock" -TimeoutSec 10 -UseBasicParsing; Add-Rep 'scanner refuses anonymous' 401 200 } catch { Add-Rep 'scanner refuses anonymous' 401 ([int]$_.Exception.Response.StatusCode) }

    if ($it) {
      $ih = @{ Authorization = "Bearer $it" }
      try { $x = Invoke-WebRequest "$api/validation/clock" -Headers $ih -TimeoutSec 10 -UseBasicParsing; Add-Rep 'inspector reaches scanner' 200 $x.StatusCode } catch { Add-Rep 'inspector reaches scanner' 200 ('ERR ' + $_.Exception.Message) }

      # A junk credential must be refused, recorded, and still return 200. A
      # forged ticket is a successful detection, not a client error, so the HTTP
      # status and the verdict stay separate.
      try {
        $s = Invoke-RestMethod "$api/validation/scan" -Method Post -Headers $ih -ContentType 'application/json' -TimeoutSec 15 -Body (@{ qrString = '{"t":"00000000-0000-0000-0000-000000000000","c":"x","i":1,"e":9999999999,"n":"zz","k":"addis-one-2026-01","s":"AAAA"}' } | ConvertTo-Json)
        Add-Rep 'scan forged credential' 200 200
        Add-Rep 'forged is not accepted' 'False' $s.accepted
        Add-Rep 'forged outcome' 'INVALID_SIGNATURE' $s.outcome
        Add-Rep 'forged scan was recorded' 'VAL-' $s.validationReference.Substring(0, 4)
      } catch { Add-Rep 'scan forged credential' 200 ('ERR ' + $_.Exception.Message) }

      # DTO validation runs before any service logic.
      try { $null = Invoke-WebRequest "$api/validation/scan" -Method Post -Headers $ih -ContentType 'application/json' -TimeoutSec 10 -Body (@{ notAField = 'x' } | ConvertTo-Json); Add-Rep 'scan rejects bad body' 400 200 } catch { Add-Rep 'scan rejects bad body' 400 ([int]$_.Exception.Response.StatusCode) }

      try { $m = Invoke-RestMethod "$api/validation/mine" -Headers $ih -TimeoutSec 10; Add-Rep 'inspector scan history' 'True' ($m.validations.Count -ge 1) } catch { Add-Rep 'inspector scan history' 'True' ('ERR ' + $_.Exception.Message) }
    }
  }
} else {
  Add-Content -Path $out -Value ('boot log: ' + ((Get-Content $log -Tail 20 -EA 0) -join ' | ')) -Encoding utf8
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0
Add-Content -Path $out -Value 'DONE' -Encoding utf8