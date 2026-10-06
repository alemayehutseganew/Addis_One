$out = "$env:TEMP\addis_pubget.txt"
$lines = @()
$lines += "=== pub get @ $(Get-Date -Format o) ==="
Push-Location 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
try {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' pub get 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
