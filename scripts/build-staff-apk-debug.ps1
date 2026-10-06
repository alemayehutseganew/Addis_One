param(
  [string]$ApiBaseUrl = 'http://192.168.13.10:3000/api/v1',
  [switch]$ViaAdbReverse,
  [switch]$NoDevSignIn
)

# Builds and installs the staff inspector app.
#
# Mirrors build-apk-debug.ps1 for the passenger app, because the two clients
# share a backend and a phone and a half-working pair is harder to test than
# either alone.

$app  = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\staff'
$out  = "$env:TEMP\addis_staff_apk_debug.txt"
$adb  = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$lines = @()
$lines += "=== staff build @ $(Get-Date -Format o) ==="

# Same reasoning as the passenger script: a phone on cellular cannot reach this
# machine's LAN address, and `adb reverse` makes loopback the correct address
# instead of an unreachable one.
if ($ViaAdbReverse) {
  & $adb reverse tcp:3000 tcp:3000 | Out-Null
  $ApiBaseUrl = 'http://127.0.0.1:3000/api/v1'
  $lines += 'adb_reverse=tcp:3000 -> tcp:3000 (loopback over USB)'
}

$lines += "api_base_url=$ApiBaseUrl"

if (-not $ViaAdbReverse -and $ApiBaseUrl -match '10\.0\.2\.2|127\.0\.0\.1|localhost') {
  $lines += 'ABORT: an emulator/localhost URL will not resolve on a physical device.'
  $lines += 'Re-run with -ViaAdbReverse to tunnel loopback over USB instead.'
  Set-Content -Path $out -Value $lines -Encoding UTF8
  Write-Output 'aborted'
  exit 1
}

Push-Location $app
try {
  # Deleted first so a failed build cannot leave the previous APK looking valid.
  Remove-Item (Join-Path $app 'build\app\outputs\flutter-apk\app-debug.apk') `
    -Force -ErrorAction SilentlyContinue

  $flutterArgs = @('build', 'apk', '--debug', '--target-platform', 'android-arm64')
  $flutterArgs += '--dart-define=API_BASE_URL=' + $ApiBaseUrl
  $flutterArgs += '--dart-define=BUILD_FLAVOUR=live'
  # The bypass sign-in is off unless asked for. A field build should never
  # carry a control that skips verification just because someone left a flag on.
  if (-not $NoDevSignIn) {
    $flutterArgs += '--dart-define=ENABLE_DEV_SIGN_IN=true'
  }
  $lines += ('args=' + ($flutterArgs -join ' '))

  $lines += (& 'C:\src\flutter\bin\flutter.bat' @flutterArgs 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }

$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-debug.apk'
$lines += 'apk_exists=' + (Test-Path $apk)

if (Test-Path $apk) {
  $f = Get-Item $apk
  $lines += 'apk_path=' + $f.FullName
  $lines += ('apk_size_mb=' + [math]::Round($f.Length / 1MB, 2))
} else {
  $lines += 'BUILD FAILED: no APK was produced.'
  Set-Content -Path $out -Value $lines -Encoding UTF8
  Write-Output "build failed; see $out"
  exit 1
}

# Install only when a device is present. A long Gradle build gives a tethered
# phone plenty of time to drop off, and failing the whole script on that would
# discard a perfectly good APK the caller still wants on disk.
$devices = (& $adb devices | Select-String '^\S+\s+device$')
if (-not $devices) {
  $lines += 'install=SKIPPED (no device attached)'
  $lines += "note=reconnect the phone and run: adb install -r $apk"
} else {
  $lines += (& $adb install -r $apk 2>&1 | Out-String)
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote $out"
