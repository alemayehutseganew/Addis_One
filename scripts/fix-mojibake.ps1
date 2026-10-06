$ErrorActionPreference = 'Stop'
$base = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger\lib'
$out  = "$env:TEMP\addis_fix_mojibake.txt"
$utf8 = New-Object System.Text.UTF8Encoding($false)  # no BOM

# UTF-8 bytes that were decoded as Latin-1 and re-encoded, twice in places.
# Detected by their code-point shapes, not by guessing at line numbers.
$map = @(
  @{ Pattern = ([char]0x00E2 + [char]0x20AC + [char]0x201D); Replacement = [char]0x2014 }  # â€” -> em dash
  @{ Pattern = ([char]0x00E2 + [char]0x2020 + [char]0x2019); Replacement = [char]0x2192 }  # â†’ -> right arrow
  @{ Pattern = ([char]0x00E2 + [char]0x20AC + [char]0x2122); Replacement = [char]0x2014 }  # â€� -> em dash
  @{ Pattern = ([char]0x00E2 + [char]0x20AC + [char]0x0153); Replacement = [char]0x2019 }  # â€™ -> apostrophe
  @{ Pattern = ([char]0x00C3 + [char]0x0097);              Replacement = [char]0x00D7 }  # Ã— -> times
  @{ Pattern = ([char]0x00C3 + [char]0x0083);              Replacement = [char]0x0192 }  # Ãƒ -> florin
)

$lines = @("=== mojibake repair @ $(Get-Date -Format o) ===")
$total = 0

Get-ChildItem $base -Recurse -Filter *.dart | ForEach-Object {
  $path = $_.FullName
  # Read and write through explicit UTF-8. Get-Content defaults to the system
  # codepage on Windows PowerShell 5.1, which is what created these in the first
  # place -- round-tripping through it would corrupt the Amharic strings.
  $text = $utf8.GetString([System.IO.File]::ReadAllBytes($path))
  $original = $text
  $count = 0

  foreach ($m in $map) {
    $parts = $text.Split($m.Pattern)
    if ($parts.Length -gt 1) {
      $count += ($parts.Length - 1)
      $text = $parts -join $m.Replacement
    }
  }

  if ($text -ne $original) {
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    $total += $count
    $lines += ("fixed " + $count + " in " + $path.Substring($base.Length + 1))
  }
}

# Verify: re-read every file and assert no replacement char or mojibake marker
# survives. Reporting "fixed" without re-reading is how this gets reintroduced.
$remaining = @()
Get-ChildItem $base -Recurse -Filter *.dart | ForEach-Object {
  $t = $utf8.GetString([System.IO.File]::ReadAllBytes($_.FullName))
  if ($t.Contains([char]0x00E2) -or $t.Contains([char]0xFFFD)) {
    $remaining += $_.FullName.Substring($base.Length + 1)
  }
}

$lines += "total_fixed=$total"
if ($remaining.Count -gt 0) {
  $lines += "STILL_DIRTY:"
  $lines += $remaining
} else {
  $lines += 'verified: no mojibake remains in lib/'
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "fixed=$total remaining=$($remaining.Count)"
