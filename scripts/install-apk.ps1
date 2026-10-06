param([switch]$Debug)

$app = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
# Default to the release APK. A debug build has a different signature and cannot
# replace it in place, so the flavour must be chosen explicitly rather than
# whichever file happens to be newest on disk.
$flavour = if ($Debug) { 'debug' } else { 'release' }
$apk = Join-Path $app "build\app\outputs\flutter-apk\app-$flavour.apk"

if (-not (Test-Path $apk)) {
  Write-Output "missing: $apk"
  exit 1
}

$sdk = "$env:LOCALAPPDATA\Android\sdk"
$buildTools = Get-ChildItem "$sdk\build-tools" -Directory -EA SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
$adb = "$sdk\platform-tools\adb.exe"
$out = "$env:TEMP\addis_install.txt"
$lines = @()
$lines += "=== verify + install ($flavour) @ $(Get-Date -Format o) ==="
$lines += ("apk=" + $apk)
$lines += ("apk_mb=" + [math]::Round((Get-Item $apk).Length / 1MB, 2))
$lines += ("apksigner=" + $apksigner)

if (Test-Path $apksigner) {
  $lines += "--- signature verify ---"
  $lines += (& $apksigner verify --verbose --print-certs $apk 2>&1 | Out-String)
  $lines += "verify_exit=$LASTEXITCODE"
}

$lines += "--- devices ---"
$lines += (& $adb devices 2>&1 | Out-String)

$lines += "--- uninstall any prior build ---"
$lines += (& $adb uninstall com.addisone.addis_one_passenger 2>&1 | Out-String)

$lines += "--- install ---"
$lines += (& $adb install -r $apk 2>&1 | Out-String)
$lines += "install_exit=$LASTEXITCODE"

$lines += "--- verify installed ---"
$lines += (& $adb shell pm list packages 2>&1 | Select-String 'addisone' | Out-String)

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
