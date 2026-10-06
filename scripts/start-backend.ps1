$bk = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\backend'
$out = Join-Path $bk 'server.log'
$err = "$out.err"
$pidFile = Join-Path $bk 'server.pid'
$buildLog = Join-Path $bk 'build.log'

# Stop the previous instance before restarting, otherwise the port stays bound
# and the new process dies with EADDRINUSE.
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
}

foreach ($f in @($out, $err, $buildLog)) {
  if (Test-Path $f) { Remove-Item $f -Force }
}

# A machine-level DATABASE_URL for another project leaks into child processes
# and breaks Prisma; clear it so this project's .env governs.
$env:DATABASE_URL = $null

Push-Location $bk
try {
  # Build with the server-only config (see tsconfig.build.json for why a
  # separate config is needed). Both dist/ and its .tsbuildinfo are removed:
  # a stale incremental cache previously made tsc emit nothing and exit 0,
  # leaving the server starting with yesterday's routes.
  if (Test-Path 'dist') { Remove-Item 'dist' -Recurse -Force }

  # Compiler output is captured rather than discarded — a silent `| Out-Null`
  # previously hid a failed build behind a server that started happily.
  & npx.cmd tsc -p tsconfig.build.json *>&1 | Out-File -FilePath $buildLog -Encoding UTF8
  if ($LASTEXITCODE -ne 0) {
    Add-Content $buildLog "BUILD_FAILED exit=$LASTEXITCODE"
    Write-Output "build failed; see $buildLog"
    exit 1
  }

  if (-not (Test-Path 'dist\main.js')) {
    Write-Output "build produced no dist\main.js; see $buildLog"
    exit 1
  }

  $p = Start-Process -FilePath 'node.exe' `
        -ArgumentList 'dist/main.js' `
        -WorkingDirectory $bk `
        -WindowStyle Hidden `
        -RedirectStandardOutput $out `
        -RedirectStandardError $err `
        -PassThru
  Set-Content $pidFile -Value $p.Id
  Write-Output "server pid=$($p.Id)"
} finally {
  Pop-Location
}
