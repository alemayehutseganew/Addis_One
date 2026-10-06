param(
  [string]$Html = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\docs\proposal\Addis-Transport-Digitalisation-Proposal.html',
  [string]$Pdf  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\docs\proposal\Addis-Transport-Digitalisation-Proposal.pdf',
  [string]$Log  = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\.print.log'
)

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
if (-not (Test-Path $edge)) {
  Set-Content -Path $Log -Value 'EDGE_NOT_FOUND' -Encoding UTF8
  exit 1
}

if (Test-Path $Pdf) { Remove-Item $Pdf -Force }

# Convert the local path to a file:/// URL. Edge's --print-to-pdf takes a URL,
# not a path, and a bare Windows path is silently ignored.
$uri = ([System.Uri]$Html).AbsoluteUri

$lines = @()
$lines += "edge=$edge"
$lines += "uri=$uri"

# Chromium's CLI cannot pass header/footer templates, and CSS margin boxes are
# ignored for --print-to-pdf. Page numbers therefore come from the browser's own
# default header/footer, which earlier revisions of this script suppressed with
# --no-pdf-header-footer. Omitting that flag lets each page carry its number.
$args = @(
  '--headless',
  '--disable-gpu',
  '--no-sandbox',
  '--run-all-compositor-stages-before-draw',
  '--virtual-time-budget=20000',
  "--print-to-pdf=$Pdf",
  $uri
)

$p = Start-Process -FilePath $edge -ArgumentList $args -NoNewWindow -PassThru -Wait
$lines += "exit=$($p.ExitCode)"

if (Test-Path $Pdf) {
  $lines += "pdf_bytes=$((Get-Item $Pdf).Length)"
} else {
  $lines += 'PDF_NOT_CREATED'
}

Set-Content -Path $Log -Value $lines -Encoding UTF8
Write-Output "wrote $Log"