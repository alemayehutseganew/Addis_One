# Verifies and installs the merged addis_one APK onto a connected device.
#
# Separate from the build because the two have very different failure shapes: a
# build can be rerun freely, whereas an install replaces a working app and is
# easy to get wrong in ways that are only visible on the handset.
#
# The pre-existing `install-apk.ps1` targets `apps\passenger` and uninstalls
# `com.addisone.addis_one_passenger`, so it would have installed the old
# passenger APK and left the merged app absent while reporting success.
param(
    [string]$AppDir = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one',
    [string]$Report = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\install-report.txt',
    [switch]$Debug
)

# The merged app's applicationId, from android/app/build.gradle.kts. The old
# passenger app used `..._passenger`, so these coexist on one handset rather than
# replacing each other — which is why a stale passenger build can be running
# while this one silently installs.
$packageId = 'com.addisone.addis_one'

$flavour = if ($Debug) { 'debug' } else { 'release' }
$apk = Join-Path $AppDir "build\app\outputs\flutter-apk\app-$flavour.apk"

$done = "${Report}.done"
foreach ($f in @($Report, $done)) { if (Test-Path $f) { Remove-Item $f -Force } }

if (-not (Test-Path $apk)) {
    Set-Content -Path $Report -Value @("missing: $apk", 'EXIT=1') -Encoding UTF8
    [System.IO.File]::WriteAllText($done, 'EXIT=1')
    Write-Output "missing: $apk"
    exit 1
}

$sdk = "$env:LOCALAPPDATA\Android\sdk"
$adb = "$sdk\platform-tools\adb.exe"
$apksigner = (Get-ChildItem "$sdk\build-tools" -Directory -EA SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
if ($apksigner) { $apksigner = Join-Path $apksigner 'apksigner.bat' }

$lines = @()
$lines += "=== addis_one install ($flavour) @ $(Get-Date -Format o) ==="
$lines += 'apk=' + $apk
$lines += 'apk_mb=' + [math]::Round((Get-Item $apk).Length / 1MB, 2)

# Confirm the artifact is signed before installing. An unsigned or debug-signed
# APK fails at install time with a message that says nothing about signing, so
# the check belongs here where the error can name the actual cause.
if (Test-Path $apksigner) {
    $lines += '--- signature verify ---'
    $lines += (& $apksigner verify --verbose --print-certs $apk 2>&1 | Out-String)
    $lines += "verify_exit=$LASTEXITCODE"
}

$lines += '--- devices ---'
$devOut = (& $adb devices 2>&1 | Out-String)
$lines += $devOut
# `device` alone is not enough: `offline` and `unauthorized` are listed with the
# same shape, and installing against either fails with an unhelpful message.
$serials = @($devOut -split "`r?`n" |
    Where-Object { $_ -match '\sdevice$' } |
    ForEach-Object { ($_ -split '\s+')[0] })
if ($serials.Count -eq 0) {
    $lines += 'no device in state "device". Unlock the handset and accept the USB debugging prompt.'
    $lines += 'EXIT=1'
    Set-Content -Path $Report -Value $lines -Encoding UTF8
    [System.IO.File]::WriteAllText($done, 'EXIT=1')
    Write-Output 'no device'
    exit 1
}
$lines += 'target_serial=' + $serials[0]

# `-r` reinstalls over an existing build, but a release APK signed with a
# different key than what is installed cannot be replaced in place. Removing
# first makes the install deterministic instead of failing on a key mismatch.
$lines += '--- uninstall prior build ---'
$lines += (& $adb -s $serials[0] uninstall $packageId 2>&1 | Out-String)

$lines += '--- install ---'
$lines += (& $adb -s $serials[0] install -r $apk 2>&1 | Out-String)
$installExit = $LASTEXITCODE
$lines += "install_exit=$installExit"

# Confirm from the package manager rather than trusting adb's exit code, which
# has been 0 for installs that did not land.
$lines += '--- verify installed ---'
$pkgs = (& $adb -s $serials[0] shell pm list packages 2>&1 | Out-String)
$lines += ($pkgs -split "`r?`n" | Where-Object { $_ -match 'addisone' } | Out-String)
$present = $pkgs -match [regex]::Escape($packageId)

if ($installExit -eq 0 -and $present) {
    $lines += "installed=$packageId"
    $lines += 'EXIT=0'
}
else {
    $lines += "INSTALL FAILED: present=$present exit=$installExit"
    $lines += 'EXIT=1'
}

$exit = if ($installExit -eq 0 -and $present) { 0 } else { 1 }
Set-Content -Path $Report -Value $lines -Encoding UTF8
[System.IO.File]::WriteAllText($done, "EXIT=$exit")
Write-Output "wrote exit=$exit"