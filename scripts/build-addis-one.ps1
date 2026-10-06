# Builds the merged addis_one APK and writes a machine-readable report.
#
# Same shape as `analyze-addis-one.ps1` and `test-addis-one.ps1`: a release
# Gradle build runs far longer than this shell's capture window, so it is started
# detached and polled via a `.done` marker.
#
# The existing `build-apk-release.ps1` is deliberately not reused. It hardcodes
# `apps\passenger` and a Flutter at `C:\src\flutter`, neither of which exists in
# this workspace, so it would have failed before compiling a line of Dart.
param(
    [string]$AppDir = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one',
    [string]$Report = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\build-report.txt',
    # Must be reachable FROM THE HANDSET, not from this machine. 10.0.2.2 is the
    # emulator's alias for the host loopback; a physical device needs this
    # machine's LAN address. `127.0.0.1` on a handset means the handset itself
    # unless `adb reverse` is tunnelling loopback over USB.
    [string]$ApiBaseUrl = 'http://192.168.5.178:3000/api/v1',
    [switch]$Demo,
    [switch]$Debug,
    # Bakes in the "Sign in without a code" control for BOTH roles.
    #
    # This only decides whether the app *offers* the shortcut. The server is the
    # authority on whether it works: DevLoginGuard 404s unless DEV_STAFF_LOGIN=true
    # and NODE_ENV!=production, and the screens probe GET /auth/dev-login before
    # showing anything. So enabling this flag against a server without the bypass
    # armed yields a build that silently omits the button rather than one that
    # offers a control which fails.
    #
    # The two gates are independent on purpose: a release build pointed at a
    # development server should not quietly grow a sign-in shortcut, and a
    # development server should not be able to force one into a shipped APK.
    [switch]$DevLogin
)

$flutter = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\flutter\bin\flutter.bat'
$done = "${Report}.done"

foreach ($f in @($Report, $done)) { if (Test-Path $f) { Remove-Item $f -Force } }

$apkName = if ($Debug) { 'app-debug.apk' } else { 'app-release.apk' }
$apk = Join-Path $AppDir "build\app\outputs\flutter-apk\$apkName"

$lines = @()
$lines += "=== addis_one build @ $(Get-Date -Format o) ==="
$lines += "api_base_url=$ApiBaseUrl"
$lines += "use_demo_data=$($Demo.IsPresent)"
$lines += "enable_dev_sign_in=$($DevLogin.IsPresent)"
$lines += "flavour=$(if ($Debug) { 'debug' } else { 'release' })"

# Refuse to build a "live" APK that cannot reach a server, rather than producing
# an app that fails every request on a handset with no explanation. The one
# exception is loopback, which is legitimate when paired with `adb reverse`.
if (-not $Demo -and $ApiBaseUrl -match '10\.0\.2\.2' ) {
    $lines += 'ABORT: 10.0.2.2 is the emulator alias for the host loopback and will not resolve on a physical device.'
    $lines += 'Pass -ApiBaseUrl with this machine''s LAN address, or -Demo for the demo flavour.'
    $lines += 'EXIT=1'
    Set-Content -Path $Report -Value $lines -Encoding UTF8
    [System.IO.File]::WriteAllText($done, 'EXIT=1')
    Write-Output 'aborted'
    exit 1
}

# Delete the previous APK first. Without this a failed build still leaves the
# last good file on disk, and the checks below would report success for an APK
# that does not contain the requested configuration.
if (Test-Path $apk) { Remove-Item $apk -Force }

Push-Location $AppDir
try {
    $flutterArgs = @('build', 'apk')
    if (-not $Debug) { $flutterArgs += '--release' } else { $flutterArgs += '--debug' }
    # Split by ABI. The connected handset is arm64-v8a, so a universal APK would
    # carry two unused architectures and roughly double the download.
    if (-not $Debug) { $flutterArgs += '--target-platform'; $flutterArgs += 'android-arm64' }

    # Each element appended in its own statement. Writing
    # `'--dart-define=X=' + $url` inline in an array literal makes PowerShell bind
    # the concatenation as a separate positional argument, so flutter receives
    # "--dart-define=API_BASE_URL=" and then a stray "http://..." target file.
    $flutterArgs += '--dart-define=API_BASE_URL=' + $ApiBaseUrl
    $flutterArgs += '--dart-define=USE_DEMO_DATA=' + $Demo.IsPresent.ToString().ToLower()
    # Always passed, true or false. AppConfig.enableDevSignIn reads it with a
    # default of false, so omitting it would be equivalent — but passing it
    # explicitly means the value in the build report always matches the flag in
    # the command line, rather than having to be inferred from an absence.
    $flutterArgs += '--dart-define=ENABLE_DEV_SIGN_IN=' + $DevLogin.IsPresent.ToString().ToLower()
    if (-not $Demo) { $flutterArgs += '--dart-define=BUILD_FLAVOUR=live' }
    $lines += ('args=' + ($flutterArgs -join ' '))

    $lines += (& $flutter @flutterArgs 2>&1 | Out-String)
    $lines += "flutter_exit=$LASTEXITCODE"
}
finally { Pop-Location }

$lines += '--- artifact ---'
$lines += 'apk_exists=' + (Test-Path $apk)
if (Test-Path $apk) {
    $f = Get-Item $apk
    $lines += 'apk_path=' + $f.FullName
    $lines += 'apk_size_mb=' + [math]::Round($f.Length / 1MB, 2)
    $lines += 'apk_built_at=' + $f.LastWriteTime.ToString('o')
}
else {
    # Loud failure: a build that produced nothing must never look like success.
    $lines += 'BUILD FAILED: no APK was produced.'
}

$exit = if (Test-Path $apk) { 0 } else { 1 }
$lines += "EXIT=$exit"

Set-Content -Path $Report -Value $lines -Encoding UTF8
[System.IO.File]::WriteAllText($done, "EXIT=$exit")
Write-Output "wrote"