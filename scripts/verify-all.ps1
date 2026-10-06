$root = 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$out  = "$env:TEMP\addis_final_verify.txt"
$lines = @()
$lines += "=== FINAL VERIFICATION @ $(Get-Date -Format o) ==="

# 1. Backend unit tests
$lines += ""
$lines += "--- backend jest ---"
Push-Location "$root\backend"
try {
  $lines += (& npx.cmd jest 2>&1 | Out-String)
  $lines += "jest_exit=$LASTEXITCODE"
} finally { Pop-Location }

# 2. Flutter analyzer
$lines += ""
$lines += "--- flutter analyze ---"
Push-Location "$root\apps\passenger"
try {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' analyze --no-fatal-infos 2>&1 | Out-String)
  $lines += "analyze_exit=$LASTEXITCODE"
} finally { Pop-Location }

# 3. Flutter tests
$lines += ""
$lines += "--- flutter test ---"
Push-Location "$root\apps\passenger"
try {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' test 2>&1 | Select-Object -Last 12 | Out-String)
  $lines += "flutter_test_exit=$LASTEXITCODE"
} finally { Pop-Location }

# 4. File inventory
$lines += ""
$lines += "--- inventory ---"
$dart = Get-ChildItem "$root\apps\passenger\lib" -Recurse -File -Filter '*.dart'
$dtests = Get-ChildItem "$root\apps\passenger\test" -Recurse -File -Filter '*.dart'
$ts = Get-ChildItem "$root\backend\src" -Recurse -File -Filter '*.ts'
$lines += ("dart_impl_files=" + $dart.Count + " lines=" + ($dart | ForEach-Object { (Get-Content $_.FullName | Measure-Object -Line).Lines } | Measure-Object -Sum).Sum)
$lines += ("dart_test_files=" + $dtests.Count)
$lines += ("ts_files=" + $ts.Count + " lines=" + ($ts | ForEach-Object { (Get-Content $_.FullName | Measure-Object -Line).Lines } | Measure-Object -Sum).Sum)

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
