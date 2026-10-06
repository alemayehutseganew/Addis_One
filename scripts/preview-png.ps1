param(
  [string]$Html = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\.slice.html',
  [string]$Png  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\.slice.png',
  [int]$Width  = 1100,
  [int]$Height = 800
)

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }

if (Test-Path $Png) { Remove-Item $Png -Force }

$uri = ([System.Uri]$Html).AbsoluteUri

$args = @(
  '--headless',
  '--disable-gpu',
  '--no-sandbox',
  '--hide-scrollbars',
  '--run-all-compositor-stages-before-draw',
  '--virtual-time-budget=15000',
  "--window-size=$Width,$Height",
  "--screenshot=$Png",
  $uri
)

$p = Start-Process -FilePath $edge -ArgumentList $args -NoNewWindow -PassThru -Wait

if (Test-Path $Png) {
  Set-Content -Path 'C:\Users\alexo\Desktop\File\Code\AddisTransport\.print.log' `
    -Value "screenshot_bytes=$((Get-Item $Png).Length)" -Encoding UTF8
  Write-Output 'SHOT_OK'
} else {
  Set-Content -Path 'C:\Users\alexo\Desktop\File\Code\AddisTransport\.print.log' `
    -Value "SHOT_FAILED exit=$($p.ExitCode)" -Encoding UTF8
  Write-Output 'SHOT_FAILED'
}