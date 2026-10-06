# Runs the merged app's test suite and writes a machine-readable report.
#
# Same shape as `analyze-addis-one.ps1`, and for the same reason: `flutter test`
# takes longer than this shell's capture window, so it is started detached and
# polled via the `.done` marker.
param(
    [string]$AppDir = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one',
    [string]$Report = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\test-report.txt'
)

$flutter = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\flutter\bin\flutter.bat'
$done = "$Report.done"

foreach ($f in @($Report, $done)) { if (Test-Path $f) { Remove-Item $f -Force } }

Push-Location $AppDir
try {
    $lines = & $flutter test --reporter expanded 2>&1 | Out-String
    [System.IO.File]::WriteAllText($Report, $lines, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($done, "EXIT=$LASTEXITCODE")
}
finally {
    Pop-Location
}