# Builds the field-test release APK: OTP + temporary test username/password.
#
# WHAT THIS PRODUCES
#   apps/addis_one/build/app/outputs/flutter-apk/app-release.apk
#   (~15-20 MB, signed, R8-shrunk) pointed at the backend address you pass.
#
# USAGE
#   # Phone + PC on the same Wi-Fi (replace with YOUR ipconfig IPv4):
#   .\scripts\build-release-apk.ps1 -BackendHost 192.168.5.178
#   # Emulator:
#   .\scripts\build-release-apk.ps1 -BackendHost 10.0.2.2
#   # USB with `adb reverse tcp:3000 tcp:3000`:
#   .\scripts\build-release-apk.ps1 -BackendHost 127.0.0.1
#
# PREREQUISITES (run once, in order):
#   1. Backend DB/Redis:  docker compose -f infra/docker-compose.yml up -d
#   2. Backend deps:      cd backend; npm install
#   3. Migrate + seed:    .\scripts\run-prisma.ps1 migrate deploy  (or migrate dev)
#                         cd backend; npx ts-node --transpile-only prisma/seed.ts
#   4. Backend env:       backend/.env must contain TEST_LOGIN_ENABLED=true
#                         (already added) and OTP_DEV_ECHO=true for OTP codes
#                         in the server log.
#   5. Backend running:   cd backend; npm run start  (listens on 0.0.0.0:3000)
#   6. Signing key:       .\scripts\make-keystore.ps1  (falls back to debug
#                         signing when absent, still installable)
#   7. Flutter SDK:       C:\src\flutter\bin\flutter.bat
#
# LOGIN AFTER INSTALL (both work while TEST_LOGIN_ENABLED=true):
#   Passenger role -> username `passenger` / password `test123`, or phone OTP
#   Staff role     -> username `staff` / password `test123`, or phone OTP
# The OTP code prints in the backend console ([DEV OTP]) until SMS is live.
param(
  [string]$BackendHost = '192.168.5.178',
  [int]$BackendPort = 3000,
  [string]$BuildFlavour = 'field-test'
)

$ErrorActionPreference = 'Stop'
$root = 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$app = Join-Path $root 'apps\addis_one'
$flutter = 'C:\src\flutter\bin\flutter.bat'
$baseUrl = "http://${BackendHost}:${BackendPort}/api/v1"

Write-Output "Addis One field-test APK"
Write-Output "  backend : $baseUrl"
Write-Output "  flavour : $BuildFlavour"
Write-Output "  logins  : passenger/test123, staff/test123, plus OTP"

if (!(Test-Path $flutter)) { throw "Flutter not found at $flutter" }

# The phone must be allowed cleartext HTTP to this host (release builds deny
# cleartext by default). Warn when the host is not allow-listed.
$netCfg = Join-Path $app 'android\app\src\main\res\xml\network_security_config.xml'
$cfgText = Get-Content $netCfg -Raw
if ($cfgText -notmatch [regex]::Escape($BackendHost)) {
  Write-Output "WARNING: $BackendHost is not in network_security_config.xml."
  Write-Output "Add: <domain includeSubdomains=`"false`">$BackendHost</domain>"
  Write-Output "or the APK will install but every request will fail."
}

Push-Location $app
try {
  & $flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
  & $flutter analyze
  if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed" }
  & $flutter test
  if ($LASTEXITCODE -ne 0) { throw "flutter test failed" }
  & $flutter build apk --release `
    --dart-define=API_BASE_URL=$baseUrl `
    --dart-define=BUILD_FLAVOUR=$BuildFlavour
  if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed" }
} finally {
  Pop-Location
}

$apk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
  $kb = [math]::Round((Get-Item $apk).Length / 1KB, 1)
  Write-Output "OK: $apk (${kb} KB)"
  Write-Output "Install: adb install -r `"$apk`""
} else {
  throw "Build reported success but $apk is missing"
}
