$b = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$marker = "$env:TEMP\addis_tc.txt"
Set-Content -Path $marker -Value ('START ' + (Get-Date -Format 'HH:mm:ss')) -Encoding utf8
Set-Location $b
$t = [System.Diagnostics.Stopwatch]::StartNew()
# --noEmit skips writing output. The full emit is the slow part in this sandbox,
# and a type error is reported identically either way.
$log = cmd /c "npx tsc --noEmit -p tsconfig.build.json 2>&1"
$t.Stop()
$lines = @()
$lines += 'elapsed=' + [int]$t.Elapsed.TotalSeconds + 's exit=' + $LASTEXITCODE
$err = ($log | Out-String).Trim()
if ($err) { $lines += $err } else { $lines += 'no type errors' }
$lines += 'DONE'
Add-Content -Path $marker -Value ($lines -join "`n") -Encoding utf8