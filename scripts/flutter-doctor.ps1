$out = "$env:TEMP\addis_flutter_doctor.txt"
$lines = @()
$lines += "=== flutter doctor @ $(Get-Date -Format o) ==="
$lines += (& 'C:\src\flutter\bin\flutter.bat' doctor -v 2>&1 | Out-String)
Set-Content -Path $out -Value $lines -Encoding UTF8

# Also report on the stray SDK copy found inside the workspace.
$stray = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\flutter'
$extra = @()
$extra += "=== stray sdk copy in workspace ==="
$extra += ("exists=" + (Test-Path $stray))
if (Test-Path $stray) {
  $extra += ("files=" + (Get-ChildItem $stray -Recurse -File -Force -EA SilentlyContinue | Measure-Object).Count)
  $extra += ("has_bin_flutter=" + (Test-Path (Join-Path $stray 'bin\flutter.bat')))
  $extra += ("has_git=" + (Test-Path (Join-Path $stray '.git')))
}
Add-Content -Path $out -Value $extra -Encoding UTF8
Write-Output "wrote"
