# Clean, deterministic rebuild.
#
# `nest build` alone proved unreliable in this sandbox: a killed command left
# `dist/` untouched, and because a stale `tsconfig.tsbuildinfo` was still present
# TypeScript's incremental compiler reported success without emitting anything.
# The result was a server that booted perfectly well and was missing every change
# just made to it — the hardest kind of bug to notice, because "it runs" and
# "it is current" are not the same claim.
#
# So: remove the output directory and the build info first, compile with plain
# tsc, then verify that the compiled main.js actually contains the new code
# rather than trusting the exit code.
$ErrorActionPreference = 'Continue'
$base = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$marker = "$env:TEMP\addis_build.txt"
$started = Get-Date

Set-Content -Path $marker -Value ('START ' + $started.ToString('HH:mm:ss')) -Encoding utf8
Set-Location $base

Remove-Item "$base\dist" -Recurse -Force -EA 0
Remove-Item "$base\tsconfig.tsbuildinfo" -Force -EA 0

$log = cmd /c "npx tsc -p tsconfig.build.json 2>&1"
$code = $LASTEXITCODE
$elapsed = [int]((Get-Date) - $started).TotalSeconds

$lines = @()
$lines += 'exit=' + $code + '  elapsed=' + $elapsed + 's'
if ($log) { $lines += ($log | Out-String).Trim() }

$main = "$base\dist\main.js"
if (Test-Path $main) {
  $text = [System.IO.File]::ReadAllText($main)
  $lines += 'dist/main.js bytes=' + $text.Length
  foreach ($needle in @('assertValidConfig', 'SwaggerModule', 'DATABASE_URL resolves')) {
    $lines += ('  contains "{0}": {1}' -f $needle, ([regex]::Matches($text, [regex]::Escape($needle))).Count -gt 0)
  }
  $lines += '  policy.js exists: ' + (Test-Path "$base\dist\modules\auth\policy.js")
  $lines += '  validate-env.js exists: ' + (Test-Path "$base\dist\config\validate-env.js")
} else {
  $lines += 'dist/main.js MISSING - compile did not produce output'
}

$lines += 'DONE'
Set-Content -Path $marker -Value ($lines -join "`n") -Encoding utf8