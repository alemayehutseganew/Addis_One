# Runs `dart analyze` for the merged app and writes a machine-readable report.
#
# `dart analyze` rather than `flutter analyze` because it does not need to load
# the Flutter tool's plugin machinery, which roughly halves the runtime — and the
# report is read repeatedly while converging on a clean tree.
#
# Started detached and polled via the `.done` marker because the analyzer takes
# longer than this shell's capture window.
param(
    [string]$AppDir = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one',
    [string]$Report = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\analyze-report.txt'
)

$dart = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\flutter\bin\dart.bat'
$done = "$Report.done"

foreach ($f in @($Report, $done)) { if (Test-Path $f) { Remove-Item $f -Force } }

Push-Location $AppDir
try {
    $lines = & $dart analyze --format machine 2>&1 | Out-String
    # Out-File with utf8 rather than the default, because the report is compared
    # against later runs and a re-encoded BOM would make every line look changed.
    [System.IO.File]::WriteAllText($Report, $lines, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($done, "EXIT=$LASTEXITCODE")
}
finally {
    Pop-Location
}