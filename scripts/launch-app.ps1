$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$pkg = 'com.addisone.addis_one_passenger'
$out = "$env:TEMP\addis_launch.txt"
$lines = @()
$lines += "=== launch @ $(Get-Date -Format o) ==="

# Resolve the launcher activity rather than guessing it.
$lines += "--- launcher activity ---"
$lines += (& $adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg 2>&1 | Out-String)
$activity = (& $adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg 2>&1 | Select-Object -Last 1)
$lines += ("resolved=" + ($activity | Out-String))

# Force-stop first so a stale process cannot hold the old UI.
$lines += (& $adb shell am force-stop $pkg 2>&1 | Out-String)

$lines += "--- start ---"
$lines += (& $adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 2>&1 | Out-String)
$lines += "start_exit=$LASTEXITCODE"

Start-Sleep -Seconds 6

$lines += "--- process alive? ---"
$lines += (& $adb shell pidof $pkg 2>&1 | Out-String)

$lines += "--- focused window ---"
# Re-read after a pause: the first check can land while the app is still
# starting, and reporting the launcher then makes a working launch look failed.
Start-Sleep -Seconds 3
$lines += (& $adb shell dumpsys window 2>&1 | Select-String 'mCurrentFocus|mFocusedApp' | Select-Object -First 4 | Out-String)

$lines += "--- recent crash markers ---"
$lines += (& $adb shell dumpsys activity exit-info $pkg 2>&1 | Select-Object -First 15 | Out-String)

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
