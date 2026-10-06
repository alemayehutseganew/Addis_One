$bk = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = Join-Path $bk 'otp-test.txt'

$env:DATABASE_URL = $null
Push-Location $bk
try {
  & node.exe -e @"
const { PrismaClient } = require('@prisma/client');
(async () => {
  const p = new PrismaClient();
  const n = await p.otpChallenge.deleteMany({});
  console.log('cleared ' + n.count + ' otp challenges');
  await p.`$disconnect();
})();
"@ 2>&1 | Out-File $out -Encoding UTF8
  $code = $LASTEXITCODE
} finally { Pop-Location }
Add-Content $out "exit=$code"
Write-Output "done"
