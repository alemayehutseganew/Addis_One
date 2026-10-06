param([int]$Seconds = 90)
Start-Sleep -Seconds $Seconds
$r = @()
$r += 'out=' + (Test-Path "$env:TEMP\addis_prisma_out.txt")
$r += 'migrations=' + (@(Get-ChildItem 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend\prisma\migrations' -Directory -EA SilentlyContinue).Count)
$r += 'node=' + (@(Get-Process node -EA SilentlyContinue).Count)
Set-Content -Path "$env:TEMP\addis_wait.txt" -Value $r -Encoding UTF8
Write-Output 'waited'
