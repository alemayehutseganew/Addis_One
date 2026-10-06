param()

# Lists every tappable element with its device coordinates, straight from the
# accessibility tree.
#
# Tapping by eyeballing a screenshot is guesswork: the pulled PNG is scaled and
# the status bar and navigation bar shift the origin. These bounds come from the
# accessibility node itself, so a tap lands on the intended control or fails
# visibly instead of quietly hitting whatever was nearby.

# adb writes progress ("1 file pulled") to stderr, which PowerShell turns into
# error records. Under 'Stop' that kills the script on a perfectly successful
# command, so it is relaxed for the adb calls and restored afterwards.
$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe"
$out = "$env:TEMP\addis_taps.txt"

& $adb shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
& $adb pull /sdcard/ui.xml "$env:TEMP\ui.xml" 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

if (-not (Test-Path "$env:TEMP\ui.xml")) {
  Set-Content -Path $out -Value 'uiautomator dump produced no file' -Encoding UTF8
  Write-Output 'dump failed'
  exit 1
}

$xml = [System.IO.File]::ReadAllText("$env:TEMP\ui.xml")
$nodes = [regex]::Matches(
  $xml,
  'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')

$lines = @("=== tappable nodes @ $(Get-Date -Format o) ===")
if ($nodes.Count -eq 0) {
  $lines += 'no nodes with a content description were found'
}
foreach ($n in $nodes) {
  $desc = $n.Groups[1].Value
  if ($desc.Trim() -eq '') { continue }
  # Cast each term explicitly before adding. Writing `($a -as [int] + $b)`
  # parses as `-as [int + $b]`, which tries to build a Type named by the sum.
  $x1 = [int]$n.Groups[2].Value
  $y1 = [int]$n.Groups[3].Value
  $x2 = [int]$n.Groups[4].Value
  $y2 = [int]$n.Groups[5].Value
  $cx = [int](($x1 + $x2) / 2)
  $cy = [int](($y1 + $y2) / 2)
  $lines += ('{0,-26} tap {1} {2}' -f $desc, $cx, $cy)
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"