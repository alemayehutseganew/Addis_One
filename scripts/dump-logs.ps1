param([string]$Pattern = 'flutter|addisone', [int]$Last = 40)

# Dumps the device log and extracts lines matching $Pattern.
#
# On-demand rather than a long-running `adb logcat` reader: two logcat clients
# compete for the same ring buffer, and the long-running one consumes the entries
# a second client would read. `logcat -d` reads and exits, so the buffer is still
# there when this runs.

$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$raw = "$env:TEMP\addis_logcat_raw.txt"
$out = "$env:TEMP\addis_logcat_hits.txt"
$pkg = 'com.addisone.addis_one_passenger'

$dump = (& $adb logcat -d -v threadtime 2>&1 | Out-String)
Set-Content -Path $raw -Value $dump -Encoding UTF8

$lines = $dump -split "`r?`n"
$hits = $lines |
  Where-Object { $_ -match $Pattern -or $_ -match $pkg } |
  Select-Object -Last $Last

# A miss is reported explicitly. An empty result and a broken capture look
# identical otherwise, and "no errors" is a claim that needs to be earned.
$status = if ($hits) { "hits=$($hits.Count)" } else { 'hits=0 (no matching lines)' }

Set-Content -Path $out -Value (@($status) + $hits) -Encoding UTF8
Write-Output $status
