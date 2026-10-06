param(
  [Parameter(Mandatory = $true)][int]$X,
  [Parameter(Mandatory = $true)][int]$Y,
  [int]$WaitSeconds = 3
)

# Taps a point on the device, but only after proving Addis One is the app in the
# foreground.
#
# The guard exists because a blind tap on the wrong foreground app is not a test
# failure, it is damage: during development this script's coordinate landed on an
# Amazon listing next to an "Add to cart" button. Every tap therefore re-checks
# the focused activity and aborts rather than firing into someone else's app.

$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$package = 'com.addisone.addis_one_passenger'
$log = "$env:TEMP\addis_tap.txt"

function Get-Foreground {
  $out = & $adb shell dumpsys window 2>&1 | Out-String
  $m = [regex]::Match($out, 'mCurrentFocus=Window\{[^}]*\s+([\w\./]+)\}')
  if ($m.Success) { return $m.Groups[1].Value }
  return 'unknown'
}

$before = Get-Foreground
$lines = @("tap $X $Y", "foreground_before=$before")

if ($before -notlike "*$package*") {
  $lines += "SKIPPED: foreground is $before, not $package"
  $lines += 'No tap was sent.'
  Set-Content -Path $log -Value $lines -Encoding UTF8
  Write-Output 'skipped'
  exit 2
}

& $adb shell input tap $X $Y 2>&1 | Out-Null
Start-Sleep -Seconds $WaitSeconds

$after = Get-Foreground
$lines += "tap sent"
$lines += "foreground_after=$after"

& $adb shell screencap -p /sdcard/addis_shot.png 2>&1 | Out-Null
& $adb pull /sdcard/addis_shot.png "$env:TEMP\addis_shot.png" 2>&1 | Out-Null
$lines += 'screenshot=$env:TEMP\addis_shot.png'

Set-Content -Path $log -Value $lines -Encoding UTF8
Write-Output 'tapped'