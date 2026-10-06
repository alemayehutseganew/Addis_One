# Starts the Postgres and Redis containers this project needs.
#
# Host ports are deliberately non-default (5433 / 6380) so this project never
# collides with another stack on the same machine. TimescaleDB is included but
# not started by default — it is a large image and only needed once the live
# vehicle-position pipeline is built.

$dk = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$compose = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\infra\docker-compose.yml'
$out = "$env:TEMP\addis_updb_out.txt"
$lines = @()
$lines += "=== compose up @ $(Get-Date -Format o) ==="

Push-Location 'c:\Users\alexo\Desktop\File\Code\AddisTransport\infra'
try {
  $lines += (& $dk compose -f $compose up -d postgres redis 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
  Start-Sleep -Seconds 8
  $lines += "=== ps ==="
  $lines += (& $dk ps --format '{{.Names}}|{{.Status}}|{{.Ports}}' 2>&1 | Out-String)
} finally { Pop-Location }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
