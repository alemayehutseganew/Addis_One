$b = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$o = @()
$o += 'now      : ' + (Get-Date -Format 'HH:mm:ss')
$o += 'dist     : ' + (Test-Path "$b\dist")
$o += 'distFile : ' + (Get-ChildItem "$b\dist" -Recurse -File -EA 0 | Measure-Object).Count
$o += 'nodeProc : ' + (Get-Process node -EA 0 | Measure-Object).Count
$o += '--- node command lines ---'
$o += (Get-CimInstance Win32_Process -Filter "Name='node.exe'" -EA 0 |
  ForEach-Object { '  ' + ($_.CommandLine -replace '\s+', ' ').Substring(0, [Math]::Min(160, $_.CommandLine.Length)) })
$o += '--- marker ---'
$o += (Get-Content "$env:TEMP\addis_build.txt" -EA 0)
$o -join "`n" | Set-Content "$env:TEMP\status.txt" -Encoding utf8