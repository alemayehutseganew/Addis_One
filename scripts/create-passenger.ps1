$out = "$env:TEMP\addis_create.txt"
$lines = @()
$lines += "=== flutter create @ $(Get-Date -Format o) ==="

$app = 'c:\Users\alexo\Desktop\File\Code\AddisTransport\apps\passenger'
if (Test-Path $app) {
  $lines += "already exists, skipping create"
} else {
  $lines += (& 'C:\src\flutter\bin\flutter.bat' create `
      --org com.addisone `
      --project-name addis_one_passenger `
      --platforms=android `
      --description "Addis One passenger app" `
      $app 2>&1 | Out-String)
  $lines += "exit=$LASTEXITCODE"
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
