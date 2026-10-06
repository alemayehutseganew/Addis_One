$bk   = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out  = Join-Path $bk 'tsc-report.txt'
$tsc  = Join-Path $bk 'node_modules\typescript\bin\tsc'

if (Test-Path $out) { Remove-Item $out -Force }

# A machine-level DATABASE_URL belonging to another project leaks into child
# processes and breaks Prisma; clearing it keeps this project's .env authoritative.
$env:DATABASE_URL = $null

Push-Location $bk
try {
  & node.exe $tsc --noEmit -p tsconfig.json *>&1 | Out-File -FilePath $out -Encoding UTF8
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

# Guarantee the file exists even on success so a poller can detect completion.
if (-not (Test-Path $out)) { Set-Content $out -Value '(no diagnostics)' }
Add-Content $out -Value "tsc_exit=$code"
Write-Output "done exit=$code"
