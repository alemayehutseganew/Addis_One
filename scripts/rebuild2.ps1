$b = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$marker = "$env:TEMP\addis_build2.txt"
Set-Content -Path $marker -Value ('START ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8
Set-Location $b
$t = [System.Diagnostics.Stopwatch]::StartNew()
$log = cmd /c "npx tsc -p tsconfig.build.json 2>&1"
# Snapshot the exit code here: $t.Stop() runs next and would overwrite it.
$exit = $LASTEXITCODE
$t.Stop()
$lines = @()
$lines += 'elapsed=' + [int]$t.Elapsed.TotalSeconds + 's exit=' + $exit

# Capture the compiler output and the exit code BEFORE any other command runs.
# cmd /c sets $LASTEXITCODE, and the very next statement overwrites it, which is
# how a failed build previously went on to print a cheerful dist summary.
$err = ($log | Out-String).Trim()

# Staleness cross-check. Even on a clean exit, tsc can leave the previous dist in
# place if emit was skipped; comparing mtimes catches a dist older than its source.
$srcNewest = (Get-ChildItem "$b\src" -Recurse -File -EA 0 |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
$distNewest = (Get-ChildItem "$b\dist" -Recurse -File -EA 0 |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
$stale = ($srcNewest -and $distNewest -and $srcNewest -gt $distNewest)

if ($exit -ne 0) {
  # Build FAILED. Say so, and do NOT run the dist assertions below: dist now holds
  # the PREVIOUS build, so asserting against it would report success for code that
  # was never compiled.
  $lines += 'BUILD FAILED (tsc exit=' + $exit + ')'
  if ($err) { $lines += $err } else { $lines += '(no compiler output)' }
  $lines += 'dist is STALE - it still holds the previous build'
  $lines += 'srcNewest : ' + $srcNewest
  $lines += 'distNewest : ' + $distNewest
  $lines += 'DO NOT run verification scripts against this dist'
  $lines += 'DONE'
  Add-Content -Path $marker -Value ($lines -join "`n") -Encoding utf8
  exit $exit
}

if ($err) { $lines += $err } else { $lines += 'no type errors' }
if ($stale) {
  $lines += 'WARNING: dist is older than src despite exit=0'
  $lines += 'srcNewest : ' + $srcNewest
  $lines += 'distNewest : ' + $distNewest
}
if (Test-Path "$b\dist\main.js") {
  $text = [System.IO.File]::ReadAllText("$b\dist\main.js")
  $lines += 'main.js has assertValidConfig: ' + $text.Contains('assertValidConfig')
  $lines += 'main.js has SwaggerModule   : ' + $text.Contains('SwaggerModule')
  $lines += 'policy.js: ' + (Test-Path "$b\dist\modules\auth\policy.js")
  $lines += 'validate-env.js: ' + (Test-Path "$b\dist\config\validate-env.js")
}
$lines += 'distFileCount: ' + (Get-ChildItem "$b\dist" -Recurse -File -EA 0 | Measure-Object).Count
$lines += 'DONE'
Add-Content -Path $marker -Value ($lines -join "`n") -Encoding utf8