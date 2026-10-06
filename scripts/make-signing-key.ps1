$ErrorActionPreference = 'Stop'
$backend = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$keyDir = Join-Path $backend 'keys'
$out    = Join-Path $keyDir 'ticket-signing-key.pem'
$done   = "$env:TEMP\addis_signkey.txt"

New-Item -ItemType Directory -Force -Path $keyDir | Out-Null

if (Test-Path $out) {
  # Replace a key that cannot actually be parsed. A file full of the right
  # markers is not proof of a usable key.
  $probe = Join-Path $backend 'probe-temp.js'
  $psrc = @'
const c = require('node:crypto');
const fs = require('node:fs');
try {
  const k = c.createPrivateKey(fs.readFileSync(process.argv[2], 'utf8'));
  console.log('ok ' + k.asymmetricKeyType);
} catch { console.log('bad'); process.exit(1); }
'@
  Set-Content -Path $probe -Value $psrc -Encoding ASCII
  try {
    $r = (& node.exe $probe $out 2>&1 | Out-String).Trim()
    $rc = $LASTEXITCODE
  } finally {
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
  }
  if ($rc -eq 0 -and $r -match 'ok ed25519') {
    Set-Content $done -Value "exists=true usable=true (kept: $r)"
    Write-Output 'done'; exit 0
  }
  Set-Content $done -Value "replaced=true (existing key was unusable)"
}

# Ed25519: the key type the credential format and the staff app's verifier both
# assume. RSA would have produced a different signature algorithm and every
# already-issued credential would fail verification.
#
# generateKeyPairSync, not a destructured shorthand — on Node 25
# `require('crypto')` resolves to a namespace object where that shorthand is not
# callable, which fails with a confusing "g is not a function".
#
# Node writes the PEM to a file directly rather than to stdout: piping it through
# PowerShell strips the newline separators, producing a valid-looking but
# unparseable single-line key that fails with "DECODER routines::unsupported".
$genScript = Join-Path $backend 'genkey-temp.js'
$gen = @'
const c = require('node:crypto');
const fs = require('node:fs');
const kp = c.generateKeyPairSync('ed25519');
fs.writeFileSync(process.argv[2], kp.privateKey.export({ type: 'pkcs8', format: 'pem' }));
'@
Set-Content -Path $genScript -Value $gen -Encoding ASCII
try {
  & node.exe $genScript $out
  if ($LASTEXITCODE -ne 0) { Set-Content $done -Value "FAILED: node exit=$LASTEXITCODE"; exit 1 }
} finally {
  Remove-Item $genScript -Force -ErrorAction SilentlyContinue
}

# Read back and verify the key parses BEFORE the server ever needs it. A key
# that only fails at first purchase is a bad afternoon.
$verify = Join-Path $backend 'verifykey-temp.js'
$vsrc = @'
const c = require('node:crypto');
const fs = require('node:fs');
const pem = fs.readFileSync(process.argv[2], 'utf8');
try {
  const k = c.createPrivateKey(pem);
  console.log('verified type=' + k.asymmetricKeyType);
} catch (e) {
  console.log('INVALID ' + e.message);
  process.exit(1);
}
'@
Set-Content -Path $verify -Value $vsrc -Encoding ASCII
try {
  $verdict = (& node.exe $verify $out 2>&1 | Out-String).Trim()
  $verifyExit = $LASTEXITCODE
} finally {
  Remove-Item $verify -Force -ErrorAction SilentlyContinue
}

if ($verifyExit -ne 0 -or $verdict -notmatch 'verified type=ed25519') {
  Set-Content $done -Value "FAILED: generated key is unusable -> $verdict"
  exit 1
}

# Windows ACL: only the current user and SYSTEM. A signing key readable by other
# local accounts is a key that will eventually be exfiltrated.
& icacls $out /inheritance:r /grant:r "$($env:USERNAME):(F)" "SYSTEM:(F)" | Out-Null

Set-Content $done -Value @(
  'created=true'
  "path=$out"
  "bytes=$((Get-Item $out).Length)"
)
Write-Output 'done'
