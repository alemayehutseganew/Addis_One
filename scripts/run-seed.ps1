$bk = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = Join-Path $bk 'seed.log'
$env:DATABASE_URL = $null

Push-Location $bk
try {
  & npx.cmd ts-node --transpile-only prisma/seed.ts *>&1 |
    Out-File -FilePath $out -Encoding UTF8
  $code = $LASTEXITCODE
} finally { Pop-Location }

Add-Content $out "seed_exit=$code"
Write-Output "done exit=$code"
