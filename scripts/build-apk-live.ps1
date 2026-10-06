# Builds a release APK pointed at the running development backend.
#
#   .\scripts\build-apk-live.ps1
#
# Passes --dart-define values so the binary is compiled against the real API
# rather than demo data. String.fromEnvironment is resolved at COMPILE time, so
# changing the API URL requires a rebuild, not a restart.
#
# The build runs through cmd.exe with redirection rather than PowerShell
# pipelines: this environment's shell restarts intermittently, and a pipeline
# only writes its log at the very end, so a killed build leaves nothing behind
# to diagnose.

param(
  [string]$HostIp = '10.168.202.175',
  [int]$Port = 3000,
  [switch]$DemoData
)

$app = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
$log = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\backend\apk-live.log'
$demo = if ($DemoData) { 'true' } else { 'false' }
$baseUrl = "http://${HostIp}:${Port}/api/v1"

$flutter = 'C:\src\flutter\bin\flutter.bat'
$cmd = "`"$flutter`" build apk --release --target-platform android-arm64 " +
       "--dart-define=API_BASE_URL=$baseUrl " +
       "--dart-define=USE_DEMO_DATA=$demo > `"$log`" 2>&1"

Set-Content $log -Value "=== live build: API_BASE_URL=$baseUrl USE_DEMO_DATA=$demo ==="

Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd `
  -WorkingDirectory $app -WindowStyle Hidden

Write-Output "launched; log=$log"
