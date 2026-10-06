# Third pass: platform scaffolding and the remaining import-path repairs.
#
# The passenger app's android/ folder is used as the base because it already had
# release signing wired up; the staff manifest's camera permissions are added to
# it, because the merged app must declare everything either half needs.

$ErrorActionPreference = 'Stop'
$apps = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps'
$dst  = Join-Path $apps 'addis_one'

# ── Android: copy the passenger scaffolding, minus build artefacts ──
$src = Join-Path $apps 'passenger\android'
Get-ChildItem $src -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\(build|\.gradle)\\' -and
    $_.Name -notin @('addis_one_passenger_android.iml', 'addis_one_passenger.iml')
} | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\')
    $out = Join-Path $dst "android\$rel"
    New-Item -ItemType Directory -Path (Split-Path $out -Parent) -Force | Out-Null
    Copy-Item $_.FullName $out -Force
}

# The Kotlin package directory and MainActivity carry the old application id.
$oldPkg = 'com\addisone\addis_one_passenger'
$newPkg = 'com\addisone\addis_one'
$ktRoot = Join-Path $dst "android\app\src\main\kotlin\$oldPkg"
if (Test-Path $ktRoot) {
    $ktNew = Join-Path $dst "android\app\src\main\kotlin\$newPkg"
    New-Item -ItemType Directory -Path $ktNew -Force | Out-Null
    Get-ChildItem $ktRoot -File | ForEach-Object {
        $c = [System.IO.File]::ReadAllText($_.FullName)
        $c = $c.Replace($oldPkg, $newPkg)
        [System.IO.File]::WriteAllText((Join-Path $ktNew $_.Name), $c)
    }
    Remove-Item (Join-Path $dst 'android\app\src\main\kotlin\com') -Recurse -Force
}

# ── applicationId / namespace ──
$gradle = Join-Path $dst 'android\app\build.gradle.kts'
$c = [System.IO.File]::ReadAllText($gradle)
$c = $c.Replace('com.addisone.addis_one_passenger', 'com.addisone.addis_one')
[System.IO.File]::WriteAllText($gradle, $c)

# ── Manifest: the merged app is both things at once ──
$manifest = Join-Path $dst 'android\app\src\main\AndroidManifest.xml'
$m = [System.IO.File]::ReadAllText($manifest)

$camera = @'
    <!-- Staff ticket validation. Scanning is the staff half's entire purpose, so
         the camera is required rather than optional: a handheld issued to an
         inspector without one is a provisioning mistake, and letting such a
         device install would just fail at the door with no camera to scan with. -->
    <uses-permission android:name="android.permission.CAMERA"/>

    <!-- Not declared optional: Play Store filtering would otherwise hide the
         app from devices that could in fact use it. -->
    <uses-feature android:name="android.hardware.camera" android:required="true"/>
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>

'@
$m = $m.Replace('    <application', $camera + '    <application')

# One binary, one label. Role identity comes from the picker, not the launcher.
$m = $m.Replace('android:label="Addis One"', 'android:label="Addis One"')

[System.IO.File]::WriteAllText($manifest, $m)

# ── project files ──
Copy-Item (Join-Path $apps 'passenger\analysis_options.yaml') (Join-Path $dst 'analysis_options.yaml') -Force
Copy-Item (Join-Path $apps 'passenger\.gitignore') (Join-Path $dst '.gitignore') -Force

Write-Output 'scaffolded'
Get-ChildItem (Join-Path $dst 'android') -Recurse -File -Filter *.kt | ForEach-Object { $_.FullName }