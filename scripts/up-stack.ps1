# Brings up the whole backend stack in ONE detached pass: Docker engine ->
# Postgres/Redis (up-db.ps1) -> Nest (start-backend.ps1), recording each step in
# a marker file.
#
# Exists because this workspace's shell restarts on foreground commands longer
# than ~20s, and neither up-db.ps1 nor start-backend.ps1 is safe to have killed
# halfway: a killed compose leaves half a stack, and a killed start-backend
# leaves no server. Run detached (Start-Process) and poll $Marker.
param(
    [string]$Marker = "$env:TEMP\addis_stack_status.txt"
)

$dk = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$scripts = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\scripts'

Remove-Item $Marker -Force -ErrorAction SilentlyContinue
Set-Content -Path $Marker -Value ('START ' + (Get-Date -Format o)) -Encoding UTF8
function Note([string]$m) { Add-Content -Path $Marker -Value $m }

# 1. Docker engine. Docker Desktop was launched separately; its engine takes a
# while to expose the named pipe, so poll rather than assume.
$limit = (Get-Date).AddSeconds(240)
$ver = $null
while ((Get-Date) -lt $limit) {
    $ver = & $dk info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $ver) { break }
    $ver = $null
    Start-Sleep -Seconds 5
}
if (-not $ver) { Note 'FAIL docker-engine-timeout'; exit 1 }
Note "docker-engine up ($ver)"

# 2. Postgres (5433) + Redis (6380).
& "$scripts\up-db.ps1"
Start-Sleep -Seconds 3
$dbUp = [bool](Get-NetTCPConnection -LocalPort 5433 -State Listen -ErrorAction SilentlyContinue)
Note "postgres_5433=$dbUp"
if (-not $dbUp) { Note 'FAIL postgres-not-listening'; exit 1 }

# 3. Nest — start-backend rebuilds dist/ first, then starts node detached.
& "$scripts\start-backend.ps1"
$limit = (Get-Date).AddSeconds(90)
$api = $false
while ((Get-Date) -lt $limit) {
    $api = [bool](Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue)
    if ($api) { break }
    Start-Sleep -Seconds 3
}
Note "api_3000=$api"
if (-not $api) { Note 'FAIL api-not-listening (see backend\server.log.err)'; exit 1 }
Note 'STACK_READY'
