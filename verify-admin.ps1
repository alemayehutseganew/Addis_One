$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$api  = 'http://127.0.0.1:3000/api/v1'
$log  = "$env:TEMP\addis_server.log"
$rep  = @()

function Add-Rep($name, $expected, $actual) {
  $script:rep += [pscustomobject]@{ Check = $name; Expected = $expected; Actual = $actual }
}

Set-Location $base
if (-not (Test-Path 'dist\main.js')) {
  npm run build *>&1 | Out-Null
  Add-Rep 'build' 'True' (Test-Path 'dist\main.js')
}

# Start the API as a PowerShell job and let the job do the output redirection.
# Start-Process -RedirectStandardOutput produced zero-byte files here, which is
# what made the previous verification run silently report nothing.
$env:OTP_DEV_ECHO = 'true'
Remove-Item $log -EA 0
$job = Start-Job -ScriptBlock {
  param($dir, $outFile)
  Set-Location $dir
  $env:OTP_DEV_ECHO = 'true'
  node dist/main.js *> $outFile
} -ArgumentList $base, $log

$up = $false
1..40 | ForEach-Object {
  if (-not $up) {
    Start-Sleep -Seconds 2
    try { if ((Invoke-WebRequest 'http://127.0.0.1:3000/api/v1/health' -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200) { $up = $true } } catch { }
  }
}
Add-Rep 'server boots' 200 $(if ($up) { 200 } else { 0 })
if (-not $up) {
  Get-Content $log -Tail 30 -EA 0 | Out-File "$env:TEMP\addis_boot.txt" -Encoding utf8
  $rep | Format-Table -AutoSize | Out-String -Width 200 | Out-File "$env:TEMP\addis_rep.txt" -Encoding utf8
  Stop-Job $job -EA 0
  Remove-Job $job -Force -EA 0
  return
}

function Get-Token($phone) {
  $null = Invoke-RestMethod "$api/auth/request-otp" -Method Post `
    -ContentType 'application/json' -Body (@{ phone = $phone } | ConvertTo-Json)
  $code = $null
  1..15 | ForEach-Object {
    if (-not $code) {
      Start-Sleep -Milliseconds 400
      $m = [regex]::Match((Get-Content $log -Raw -EA 0), 'code[:\s]+(\d{6})')
      if ($m.Success) { $code = $m.Groups[1].Value }
    }
  }
  if (-not $code) { return $null }
  $r = Invoke-RestMethod "$api/auth/verify-otp" -Method Post -ContentType 'application/json' `
    -Body (@{ phone = $phone; code = $code } | ConvertTo-Json)
  return $r.accessToken
}

function Get-Status($path, $token, $method = 'Get', $body = $null) {
  try {
    $p = @{ Headers = @{ Authorization = "Bearer $token" }; Method = $method; TimeoutSec = 20; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($body) { $p['Body'] = ($body | ConvertTo-Json -Depth 5); $p['ContentType'] = 'application/json' }
    $resp = Invoke-WebRequest ($api + $path) @p
    return @{ code = [int]$resp.StatusCode; data = ($resp.Content | ConvertFrom-Json) }
  } catch {
    $c = 0
    if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
    return @{ code = $c; data = $null }
  }
}

$bureau = Get-Token '+251911000001'
Add-Rep 'bureau signs in' 'token' $(if ($bureau) { 'token' } else { 'null' })

if ($bureau) {
  $p = (Get-Status '/dashboard/session' $bureau).data.permissions
  Add-Rep 'session canManage'       'True' $p.canManage
  Add-Rep 'session canManageStaff'  'True' $p.canManageStaff
  Add-Rep 'session canViewDatabase' 'True' $p.canViewDatabase

  $db = Get-Status '/dashboard/database' $bureau
  Add-Rep 'database panel' 200 $db.code
  Add-Rep 'db reports size'   'True' $(if ($db.data.database.sizeBytes -gt 0) { 'True' } else { 'False' })
  Add-Rep 'db reports tables' 'True' $(if ($db.data.objects.tables -gt 0) { 'True' } else { 'False' })
  Add-Rep 'db flags estimates' 'True' $db.data.notes.rowCountsAreEstimates

  foreach ($r in @('operators', 'stops', 'routes', 'vehicles', 'fare-rules', 'staff')) {
    Add-Rep "GET /admin/$r" 200 (Get-Status "/admin/$r" $bureau).code
  }
# Write round trip: create a stop, then deactivate it. No delete endpoint exists.
  $code = 'ZZT' + (Get-Random -Maximum 9000 + 1000)
  $c = Get-Status '/admin/stops' $bureau 'Post' @{
      code = $code; name = 'Verification Stop'; latitude = 9.0192; longitude = 38.7525 }
  Add-Rep 'create stop' 201 $c.code
  if ($c.data -and $c.data.id) {
    Add-Rep 'deactivate stop' 200 (Get-Status "/admin/stops/$($c.data.id)/active" $bureau 'Put' @{ isActive = $false }).code
  }
  Add-Rep 'rejects invalid stop' 400 (Get-Status '/admin/stops' $bureau 'Post' @{
      code = 'bad code!'; name = ''; latitude = 999 }).code

  # Fare versioning (I3): a revision supersedes, it never mutates.
  $f = Get-Status '/admin/fare-rules' $bureau 'Post' @{
      ruleKey = 'VERIFY-KEY'; mode = 'BUS'; baseFareFils = 1500
      changeReason = 'automated verification' }
  Add-Rep 'create fare v1' 201 $f.code
  $f2 = Get-Status '/admin/fare-rules' $bureau 'Post' @{
      ruleKey = 'VERIFY-KEY'; mode = 'BUS'; baseFareFils = 1700
      changeReason = 'automated verification raise' }
  Add-Rep 'fare revision v2' 201 $f2.code
  Add-Rep 'fare version incremented' 2 $f2.data.version
  Add-Rep 'new fare is a draft' 'DRAFT' $f2.data.status
  Add-Rep 'fare needs a reason' 400 (Get-Status '/admin/fare-rules' $bureau 'Post' @{
      ruleKey = 'VERIFY-KEY'; mode = 'BUS'; baseFareFils = 1800; changeReason = '' }).code
  if ($f.data -and $f.data.id) {
    # Dual control: the author may not approve their own draft.
    Add-Rep 'cannot self-approve a draft' 403 (Get-Status "/admin/fare-rules/$($f.data.id)/activate" $bureau 'Post').code
  }
}

# ── Operator admin: operator-scoped, and must not reach staff or the DB ────
# +251911000002 is the FINANCE officer, which is city-wide, so it would assert
# nothing about scoping. The operator-scoped admin is +251911000003.
$op = Get-Token '+251911000003'
if ($op) {
  $so = (Get-Status '/dashboard/session' $op).data.permissions
  Add-Rep 'operator canManage'      'True'  $so.canManage
  Add-Rep 'operator canManageStaff' 'False' $so.canManageStaff
  Add-Rep 'operator cannot see db'  'False' $so.canViewDatabase
  Add-Rep 'operator db blocked'         403 (Get-Status '/dashboard/database' $op).code
  Add-Rep 'operator staff list blocked' 403 (Get-Status '/admin/staff' $op).code
}

$rep | Format-Table -AutoSize | Out-String -Width 200 | Out-File "$env:TEMP\addis_rep.txt" -Encoding utf8
Stop-Job $job -EA 0
Remove-Job $job -Force -EA 0