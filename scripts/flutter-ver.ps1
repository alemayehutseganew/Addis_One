$out = "$env:TEMP\addis_flutter_ver.txt"
$lines = @()
$lines += "=== flutter --version @ $(Get-Date -Format o) ==="
$lines += (& 'C:\src\flutter\bin\flutter.bat' --version 2>&1 | Out-String)
$lines += "exit=$LASTEXITCODE"
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
