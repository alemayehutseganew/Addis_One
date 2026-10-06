param([switch]$Stop)

$adb    = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$pkg    = 'com.addisone.addis_one_passenger'
$log    = "$env:TEMP\addis_logcat.txt"
$pidOut = "$env:TEMP\addis_logcat.pid"
$ready  = "$env:TEMP\addis_logcat.ready"

if ($Stop) {
  if (Test-Path $pidOut) {
    $old = Get-Content $pidOut -ErrorAction SilentlyContinue
    if ($old) {
      # Stop the logcat client, not the app: killing adb does not disturb the
      # running app, so a pause in log reading cannot crash the thing under test.
      Get-Process adb -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne [int]$old } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item $ready -Force -ErrorAction SilentlyContinue
  Write-Output 'stopped'
  exit 0
}

# Clear first so the file contains this session only, not a backlog that makes a
# fresh run look like the current one is still failing.
& $adb logcat -c 2>&1 | Out-Null
Remove-Item $log -Force -ErrorAction SilentlyContinue

# -v threadtime includes the tag and PID, so a message can be traced to the app.
#
# The package filter must be built by concatenation, not interpolation: in
# PowerShell "$pkg:V" is read as a scoped VARIABLE named pkg:V and expands to an
# empty string, so Start-Process is handed a null argument and refuses to start.
$pkgFilter = $pkg + ':V'

# Filters are OR'd, so listing tags widens what is kept and the trailing `*:S`
# silences everything else — otherwise the buffer fills with unrelated device
# noise and the one line that matters is impossible to find.
#
# AndroidRuntime and the network tags are included deliberately: a blocked
# cleartext request is reported by the platform under its own tag, not by
# Flutter, and with only `flutter:*` that failure is entirely invisible.
$argList = @(
  'logcat', '-v', 'threadtime',
  'flutter:V', 'flutter:E', 'flutter:W',
  $pkgFilter,
  'AndroidRuntime:E',
  'ActivityManager:E',
  'NetworkSecurityPolicy:V',
  'Conscrypt:V',
  '*:S'
)

$p = Start-Process -FilePath $adb `
  -ArgumentList $argList `
  -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
  -WindowStyle Hidden -PassThru

Set-Content $pidOut -Value $p.Id
Start-Sleep -Seconds 3
# A ready marker lets a caller tell "logcat is capturing" from "the file does not
# exist yet", which otherwise reads as a failed start.
Set-Content $ready -Value @(
  'capturing=true'
  "log=$log"
  "pid=$($p.Id)"
)
Write-Output 'capturing'
