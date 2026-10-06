param(
  # Base URL baked into the build. Must be reachable FROM THE PHONE, not from
  # this machine: 10.0.2.2 works only on the emulator, and localhost on the
  # handset means the handset itself.
  [string]$ApiBaseUrl = 'http://192.168.13.10:3000/api/v1',
  [switch]$Demo
)

$app  = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
$out  = "$env:TEMP\addis_apk_release.txt"
$lines = @()
$lines += "=== flutter build apk --release @ $(Get-Date -Format o) ==="
$lines += "api_base_url=$ApiBaseUrl"
$lines += "use_demo_data=$($Demo.IsPresent)"

# Refuse to build a "live" APK that cannot possibly reach a server, rather than
# shipping an app that fails every request on a handset with no explanation.
if (-not $Demo -and $ApiBaseUrl -match '10\.0\.2\.2|127\.0\.0\.1|localhost') {
  $lines += 'ABORT: an emulator/localhost URL will not resolve on a physical device.'
  $lines += 'Pass -ApiBaseUrl with this machine''s LAN address, or -Demo to build the demo flavour.'
  Set-Content -Path $out -Value $lines -Encoding UTF8
  Write-Output 'aborted'
  exit 1
}

Push-Location $app
try {
  # Delete the previous APK first. Without this a failed build still leaves the
  # last good file on disk, and the checks below would report success for an APK
  # that does not contain the requested configuration.
  Remove-Item (Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk') `
    -Force -ErrorAction SilentlyContinue

  # Split by ABI: the device is arm64-v8a, so a universal APK would carry two
  # unused architectures and roughly double the download.
  #
  # Each element is built in its own statement. Writing
  # `'--dart-define=X=' + $url` inline in an array literal makes PowerShell bind
  # the concatenation as a separate positional argument, so flutter receives
  # "--dart-define=API_BASE_URL=" and then a stray "http://..." target file.
  $flutterArgs = @('build', 'apk', '--release', '--target-platform', 'android-arm64')
  $flutterArgs += '--dart-define=API_BASE_URL=' + $ApiBaseUrl
  $flutterArgs += '--dart-define=USE_DEMO_DATA=' + $Demo.IsPresent.ToString().ToLower()
  if (-not $Demo) { $flutterArgs += '--dart-define=BUILD_FLAVOUR=live' }
  $lines += ('args=' + ($flutterArgs -join ' '))

  $lines += (& 'C:\src\flutter\bin\flutter.bat' @flutterArgs 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }

$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
$lines += "apk_exists=" + (Test-Path $apk)
if (Test-Path $apk) {
  $f = Get-Item $apk
  $lines += ("apk_path=" + $f.FullName)
  $lines += ("apk_size_mb=" + [math]::Round($f.Length / 1MB, 2))
  $lines += ("apk_built_at=" + $f.LastWriteTime.ToString('o'))
} else {
  # Loud failure: a build that produced nothing must never look like success.
  $lines += 'BUILD FAILED: no APK was produced.'
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
