$ErrorActionPreference = 'Continue'
$root = 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$adb  = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$out  = Join-Path $env:TEMP 'devlc.txt'

$lines = @()
$lines += "=== $(Get-Date -Format o) ==="

$lines += '--- reverse ---'
$lines += ((& $adb reverse tcp:3000 tcp:3000 2>&1) | Out-String).Trim()
$lines += ((& $adb reverse --list 2>&1) | Out-String).Trim()

& $adb shell am force-stop com.addisone.addis_one_passenger | Out-Null
& $adb logcat -c | Out-Null
$lines += '--- start ---'
$lines += ((& $adb shell am start -n com.addisone.addis_one_passenger/.MainActivity 2>&1) | Out-String).Trim()

Start-Sleep -Seconds 35

$lines += '--- app http log ---'
$lines += ((& $adb logcat -d -v brief 2>&1 | Select-String 'ADDIS-HTTP|flutter' ) | Out-String).Trim()

Set-Content -Path $out -Value ($lines -join "`n") -Encoding UTF8
Write-Output 'saved'