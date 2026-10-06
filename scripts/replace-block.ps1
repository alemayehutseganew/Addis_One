# Replaces a block of Dart source, matching the file's own line endings.
#
# The editor tool normalises newlines to LF, so a multi-line match against a
# CRLF file silently fails. This reads bytes, preserves whatever the file
# already uses, and verifies the replacement actually happened — a no-op that
# reports success is worse than an error.
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$Old,
  [Parameter(Mandatory = $true)][string]$New,
  [int]$Expected = 1
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = $utf8.GetString([System.IO.File]::ReadAllBytes($Path))

$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$oldText = $Old -replace "`r`n", "`n" -replace "`n", $nl
$newText = $New -replace "`r`n", "`n" -replace "`n", $nl

$count = ([regex]::Matches($text, [regex]::Escape($oldText))).Count
if ($count -ne $Expected) {
  Write-Error "expected $Expected occurrence(s) of the block, found $count in $Path"
  exit 1
}

$text = $text.Replace($oldText, $newText)
[System.IO.File]::WriteAllText($Path, $text, $utf8)
Write-Output "replaced $count occurrence(s) in $Path"