$app = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
$out = "$env:TEMP\addis_ftest.txt"
$lines = @()
$lines += "=== flutter test @ $(Get-Date -Format o) ==="
Push-Location $app
try {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' test 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
