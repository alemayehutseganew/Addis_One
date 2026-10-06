# Builds and runs the merged addis_one app on a connected device, logging to a file.
#
# Same detached-job shape as build-addis-one.ps1: `flutter run` outlives this
# shell's capture window, so start it with Start-Process and read the log.
param(
    [string]$AppDir = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one',
    [string]$Log = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\run-report.txt',
    [string]$Device = 'R9ZX405YBRZ',
    # 127.0.0.1 on the handset is tunnelled to this machine by `adb reverse`.
    [string]$ApiBaseUrl = 'http://127.0.0.1:3000/api/v1',
    [switch]$Demo,
    [switch]$DevLogin
)

$flutter = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\flutter\bin\flutter.bat'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'

"=== addis_one run @ $(Get-Date -Format o) ===" | Set-Content $Log -Encoding UTF8

Push-Location $AppDir
try {
    "--- pub get ---" | Add-Content $Log
    & $flutter pub get 2>&1 | Out-String | Add-Content $Log

    if (Test-Path $adb) {
        "--- adb reverse ---" | Add-Content $Log
        & $adb -s $Device reverse tcp:3000 tcp:3000 2>&1 | Out-String | Add-Content $Log
    }
    else { "adb not found at $adb" | Add-Content $Log }

    $up = [bool](Test-NetConnection -ComputerName 127.0.0.1 -Port 3000 -WarningAction SilentlyContinue).TcpTestSucceeded
    "backend_port_3000_open=$up" | Add-Content $Log

    $args = @('run', '-d', $Device, '--debug')
    $args += '--dart-define=API_BASE_URL=' + $ApiBaseUrl
    $args += '--dart-define=USE_DEMO_DATA=' + $Demo.IsPresent.ToString().ToLower()
    $args += '--dart-define=ENABLE_DEV_SIGN_IN=' + $DevLogin.IsPresent.ToString().ToLower()
    "args=$($args -join ' ')" | Add-Content $Log
    "--- flutter run ---" | Add-Content $Log
    & $flutter @args 2>&1 | ForEach-Object { $_.ToString() } | Add-Content $Log
    "flutter_exit=$LASTEXITCODE" | Add-Content $Log
}
finally { Pop-Location }
