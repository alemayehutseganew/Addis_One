# Phase 1 gate: config validation, Swagger mount, and a live boot.
#
# Written as one script because the sandbox terminates background processes
# between shell invocations, so "start the server" and "probe the server" must
# happen inside the same process. Every result is written to a single report
# file for the same reason: stdout from these backgrounded runs is not reliably
# captured.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api = 'http://127.0.0.1:3000/api/v1'
$log = "$env:TEMP\addis_phase1.log"
$out = "$env:TEMP\addis_phase1_report.txt"
$rep = @()

function Add-Rep($name, $expected, $actual) {
  $script:rep += [pscustomobject]@{ Check = $name; Expected = $expected; Actual = $actual }
}

# ── 1. The stale value that caused the P1012 outage ─────────────────────────
# User and Machine scope are already cleared; the inherited process value still
# has to go, or every child process (npm, prisma, node) keeps seeing it.
$env:DATABASE_URL = $null
Add-Rep 'process DATABASE_URL cleared' '' $env:DATABASE_URL

Set-Location $base

# ── 2. Prisma can now resolve the datasource ────────────────────────────────
cmd /c "npx prisma validate > `"$env:TEMP\pv.txt`" 2>&1"
Add-Rep 'prisma validate' 0 $LASTEXITCODE

# ── 3. Fail-fast config check ───────────────────────────────────────────────
$env:DATABASE_URL = 'mysql://someone:pw@localhost:3306/other_project'
$bad = cmd /c "node dist/config/validate-env.js"
Add-Rep 'rejects non-postgres URL' 'postgresql' ($bad | Out-String).Trim()

$env:DATABASE_URL = $null
$good = cmd /c "node -e `"require('./dist/config/validate-env.js').assertValidConfig({DATABASE_URL:'postgresql://u:p@h:5432/d',JWT_ACCESS_SECRET:'x'.repeat(40),NODE_ENV:'development'});console.log('ACCEPTED')`""
Add-Rep 'accepts valid config' 'ACCEPTED' ($good | Out-String).Trim()

# ── 4. Live boot ────────────────────────────────────────────────────────────
Remove-Item $log -EA 0
$env:OTP_DEV_ECHO = 'true'
$job = Start-Job -ScriptBlock {
  param($dir, $outFile)
  Set-Location $dir
  $env:DATABASE_URL = $null
  $env:OTP_DEV_ECHO = 'true'
  node dist/main.js *> $outFile
} -ArgumentList $base, $log

$up = $false
1..45 | ForEach-Object {
  if (-not $up) {
    Start-Sleep -Seconds 2
    try {
      if ((Invoke-WebRequest "$api/health" -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200) { $up = $true }
    } catch { }
  }
}
Add-Rep 'server boots' 200 $(if ($up) { 200 } else { 0 })

if ($up) {
  foreach ($probe in @(
      @{ p = '/api/docs'; n = 'swagger ui' },
      @{ p = '/api/docs-json'; n = 'openapi json' },
      @{ p = '/dashboard/'; n = 'dashboard page' })) {
    try {
      $r = Invoke-WebRequest ('http://127.0.0.1:3000' + $probe.p) -TimeoutSec 15 -UseBasicParsing
      Add-Rep $probe.n 200 $r.StatusCode
      if ($probe.n -eq 'openapi json') {
        $j = $r.Content | ConvertFrom-Json
        Add-Rep 'openapi lists paths' 'True' ($j.paths.PSObject.Properties.Count -gt 20)
        Add-Rep 'openapi has bearer scheme' 'True' ($null -ne $j.components.securitySchemes)
      }
    } catch { Add-Rep $probe.n 200 ('ERR ' + $_.Exception.Message) }
  }

  # A real sign-in proves guards, OTP and Prisma all still work after the
  # controller rewiring.
  $null = Invoke-RestMethod "$api/auth/request-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000001' } | ConvertTo-Json)
  $code = $null
  1..15 | ForEach-Object {
    if (-not $code) {
      Start-Sleep -Milliseconds 400
      $m = [regex]::Match((Get-Content $log -Raw -EA 0), 'code[:\s]+(\d{6})')
      if ($m.Success) { $code = $m.Groups[1].Value }
    }
  }
  Add-Rep 'otp issued' '6-digit' $(if ($code) { '6-digit' } else { 'none' })
  if ($code) {
    $t = (Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' -Body (@{ phone = '+251911000001'; code = $code } | ConvertTo-Json)).accessToken
    Add-Rep 'bureau signs in' 'token' $(if ($t) { 'token' } else { 'null' })
    if ($t) {
      $h = @{ Authorization = "Bearer $t" }
      try { $s = Invoke-RestMethod "$api/dashboard/session" -Headers $h -TimeoutSec 15; Add-Rep 'session canManage' 'True' $s.permissions.canManage } catch { Add-Rep 'session canManage' 'True' ('ERR ' + $_.Exception.Message) }
      foreach ($r in @('operators', 'stops', 'routes', 'vehicles', 'fare-rules', 'staff')) {
        try { $x = Invoke-WebRequest "$api/admin/$r" -Headers $h -TimeoutSec 15 -UseBasicParsing; Add-Rep "GET /admin/$r" 200 $x.StatusCode } catch { Add-Rep "GET /admin/$r" 200 ('ERR ' + $_.Exception.Message) }
      }
    }
  }
}

Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0

$head = "PHASE 1 REPORT  " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`n`n"
$head += ($rep | Format-Table -AutoSize | Out-String -Width 200)
$head += "`n--- boot log tail ---`n" + ((Get-Content $log -Tail 25 -EA 0) -join "`n")
Set-Content -Path $out -Value $head -Encoding utf8