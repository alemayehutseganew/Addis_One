param(
  [string]$ApiBaseUrl = 'http://192.168.13.10:3000/api/v1',
  [switch]$Demo,
  [switch]$ViaAdbReverse
)

$app  = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
$out  = "$env:TEMP\addis_apk_debug.txt"
$adb  = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$lines = @()
$lines += "=== flutter build apk --debug @ $(Get-Date -Format o) ==="

# A phone on USB is frequently on cellular, or on a different network from this
# machine, so it cannot reach this machine's LAN address at all — the symptom is
# every request failing with no error on the phone. `adb reverse` tunnels the
# phone's own 127.0.0.1:3000 to this machine's localhost:3000 over USB, which
# makes loopback the CORRECT address here rather than the wrong one the guard
# below is guarding against.
if ($ViaAdbReverse) {
  & $adb reverse tcp:3000 tcp:3000 | Out-Null
  $ApiBaseUrl = 'http://127.0.0.1:3000/api/v1'
  $lines += 'adb_reverse=tcp:3000 -> tcp:3000 (loopback via USB)'
}

$lines += "api_base_url=$ApiBaseUrl"
$lines += "use_demo_data=$($Demo.IsPresent)"

if (-not $Demo -and -not $ViaAdbReverse -and $ApiBaseUrl -match '10\.0\.2\.2|127\.0\.0\.1|localhost') {
  $lines += 'ABORT: an emulator/localhost URL will not resolve on a physical device.'
  $lines += 'Re-run with -ViaAdbReverse to tunnel loopback over USB instead.'
  Set-Content -Path $out -Value $lines -Encoding UTF8
  Write-Output 'aborted'
  exit 1
}

Push-Location $app
try {
  # Deleted first: a failed build must not leave the previous APK looking valid.
  Remove-Item (Join-Path $app 'build\app\outputs\flutter-apk\app-debug.apk') `
    -Force -ErrorAction SilentlyContinue

  $flutterArgs = @('build', 'apk', '--debug', '--target-platform', 'android-arm64')
  $flutterArgs += '--dart-define=API_BASE_URL=' + $ApiBaseUrl
  $flutterArgs += '--dart-define=USE_DEMO_DATA=' + $Demo.IsPresent.ToString().ToLower()
  if (-not $Demo) { $flutterArgs += '--dart-define=BUILD_FLAVOUR=live' }
  $lines += ('args=' + ($flutterArgs -join ' '))

  $lines += (& 'C:\src\flutter\bin\flutter.bat' @flutterArgs 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }

$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-debug.apk'
$lines += "apk_exists=" + (Test-Path $apk)
if (Test-Path $apk) {
  $f = Get-Item $apk
  $lines += ("apk_path=" + $f.FullName)
  $lines += ("apk_size_mb=" + [math]::Round($f.Length / 1MB, 2))
  # A debug build is signed with the Android debug key, so it cannot replace the
  # release build in place. The installer must uninstall first; recording that
  # here avoids rediscovering it as INSTALL_FAILED_UPDATE_INCOMPATIBLE.
  $lines += 'note=debug key; uninstall the release build before installing this'
} else {
  $lines += 'BUILD FAILED: no APK was produced.'
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
