$bk = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = "$env:TEMP\addis_vectors.txt"
$lines = @()
$lines += "=== emit vectors @ $(Get-Date -Format o) ==="
Push-Location $bk
try {
  $lines += (& npx.cmd ts-node --transpile-only ..\scripts\emit-vectors.ts 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
