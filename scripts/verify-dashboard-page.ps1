$base  = 'http://127.0.0.1:3000'
$out   = "$env:TEMP\addis_dash_page.txt"
$lines = @()
$lines += "=== dashboard page check @ $(Get-Date -Format o) ==="

function Get-Code($url) {
  try { Invoke-WebRequest -Uri $url -TimeoutSec 20 -UseBasicParsing | Out-Null; return 200 }
  catch { return [int]$_.Exception.Response.StatusCode }
}

# The page and its script must be served, and must NOT be under the API prefix.
$lines += "GET /dashboard/          -> " + (Get-Code "$base/dashboard/")
$lines += "GET /dashboard/index.html-> " + (Get-Code "$base/dashboard/index.html")
$lines += "GET /dashboard/dashboard.js -> " + (Get-Code "$base/dashboard/dashboard.js")

# A page that 200s but is empty would render as a blank screen in a browser.
try {
  $html = (Invoke-WebRequest -Uri "$base/dashboard/" -TimeoutSec 20 -UseBasicParsing).Content
  $lines += "html_bytes=$($html.Length)"
  $lines += "has_title=$($html -match 'Addis One')"
  $lines += "has_script=$($html -match 'dashboard\.js')"
  $lines += "has_login_form=$($html -match 'btn-send')"
  # No external resource may be referenced: the page has to work offline.
  $lines += "external_refs=$(([regex]::Matches($html,'(?:src|href)="https?://')).Count)"
  $lines += "has_no_inline_handler=$(-not ($html -match 'on(click|load|error)='))"
} catch { $lines += "html_error=$($_.Exception.Message)" }

# The API must still be versioned and the dashboard must not be under it.
$lines += "GET /api/v1/health -> " + (Get-Code "$base/api/v1/health")
$lines += "GET /api/v1/dashboard/overview (unauth) -> " + (Get-Code "$base/api/v1/dashboard/overview")

# Security headers a government page should carry.
try {
  $r = Invoke-WebRequest -Uri "$base/dashboard/" -TimeoutSec 20 -UseBasicParsing
  $lines += "x_frame_options=$($r.Headers['X-Frame-Options'])"
  $lines += "content_security_policy=$($r.Headers['Content-Security-Policy'])"
  $lines += "content_type=$($r.Headers['Content-Type'])"
} catch { $lines += "header_error=$($_.Exception.Message)" }

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output 'done'
