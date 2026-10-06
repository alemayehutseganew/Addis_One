$app = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
$out = "$env:TEMP\addis_analyze.txt"
$lines = @()
$lines += "=== flutter analyze (cold) @ $(Get-Date -Format o) ==="

# The analyzer caches results by path+mtime. Files rewritten via PowerShell kept
# stale entries, producing phantom "uri_does_not_exist" errors for files that
# plainly exist. A clean forces a truthful cold analysis.
$lines += (& 'C:\src\flutter\bin\flutter.bat' clean 2>&1 | Out-String)

Push-Location $app
try {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' pub get 2>&1 | Out-String)
  $lines += "=== analyze ==="
  $lines += (& 'C:\src\flutter\bin\flutter.bat' analyze --no-fatal-infos 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
} finally { Pop-Location }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
