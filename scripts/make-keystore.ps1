$android = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger\android'
$out = "$env:TEMP\addis_keystore.txt"
$lines = @()
$lines += "=== keystore generation @ $(Get-Date -Format o) ==="

$keystore = Join-Path $android 'app\addis-one-release.jks'
$keyprops  = Join-Path $android 'key.properties'

# Demo/pilot signing credentials. A REAL production key must be generated in a
# secure environment and never committed; the passwords below are placeholders
# so this repo is usable out of the box.
$storePass = 'addisone-dev-2026'
$keyPass   = 'addisone-dev-2026'
$alias     = 'addis-one'
$dn        = 'CN=Addis One, OU=Transport Bureau, O=Addis One, L=Addis Ababa, C=ET'

if (Test-Path $keystore) {
  $lines += "keystore already exists"
} else {
  # 10000 days (~27y) so the key outlives any plausible app version, and so
  # Android does not reject the APK as expired.
  $args = @(
    '-genkeypair',
    '-keystore', $keystore,
    '-storetype', 'JKS',
    '-keyalg', 'RSA',
    '-keysize', '2048',
    '-validity', '10000',
    '-alias', $alias,
    '-storepass', $storePass,
    '-keypass', $keyPass,
    '-dname', $dn
  )
  $lines += (& keytool.exe @args 2>&1 | Out-String)
  $lines += "keytool_exit=$LASTEXITCODE"
}

# key.properties is read by build.gradle.kts. Never commit it.
#
# storeFile uses a FORWARD slash deliberately: java.util.Properties.load()
# treats a backslash as an escape character, so "app\addis-one-release.jks"
# parses as "appaddis-one-release.jks" and signing fails with a confusing
# "keystore not found" error.
$props = @(
  "storePassword=$storePass"
  "keyPassword=$keyPass"
  "keyAlias=$alias"
  'storeFile=app/addis-one-release.jks'
)
[System.IO.File]::WriteAllText($keyprops, ($props -join "`r`n") + "`r`n")

$lines += "keystore_exists=" + (Test-Path $keystore)
$lines += "keyprops_exists=" + (Test-Path $keyprops)
if (Test-Path $keystore) {
  $lines += ("keystore_kb=" + [math]::Round((Get-Item $keystore).Length / 1KB, 1))
  $lines += "--- certificate ---"
  $lines += (& keytool.exe -list -v -keystore $keystore -storepass $storePass -alias $alias 2>&1 | Select-Object -First 12 | Out-String)
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
