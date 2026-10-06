$bk = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = "$env:TEMP\at_jest.txt"
$lines = @()
$lines += "=== jest @ $(Get-Date -Format o) ==="

Push-Location $bk
try {
  $lines += (& npx.cmd jest 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
