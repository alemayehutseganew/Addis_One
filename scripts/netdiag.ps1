$out = "$env:TEMP\addis_netdiag.txt"
$lines = @()
$lines += "=== network diagnostics @ $(Get-Date -Format o) ==="

$lines += "--- proxy env vars ---"
foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY','http_proxy','https_proxy','JAVA_TOOL_OPTIONS','GRADLE_OPTS') {
  $val = [Environment]::GetEnvironmentVariable($v)
  $lines += ("{0}={1}" -f $v, $(if ($val) { $val } else { '(unset)' }))
}
$lines += "--- winhttp proxy ---"
$lines += (netsh winhttp show proxy 2>&1 | Out-String)
$lines += "--- IE proxy ---"
$lines += (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue |
  Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Out-String)

$lines += "--- TLS reachability (.NET) ---"
$urls = @(
  'https://storage.googleapis.com/download.flutter.io/io/flutter/arm64_release/1.0.0-af7e796e161ae0bb1ff0758c71a7105418bd9ded/arm64_release-1.0.0-af7e796e161ae0bb1ff0758c71a7105418bd9ded.pom',
  'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/8.7.3/gradle-8.7.3.pom',
  'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.1.0/kotlin-stdlib-2.1.0.pom'
)
foreach ($u in $urls) {
  try {
    $r = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 25 -UseBasicParsing
    $lines += ("OK   {0} -> {1}" -f $r.StatusCode, $u)
  } catch {
    $lines += ("FAIL {0} :: {1}" -f $u, $_.Exception.Message)
  }
}

$lines += "--- curl.exe (uses its own TLS stack) ---"
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue)
if ($curl) {
  $lines += ("curl=" + $curl.Source)
  $r = & curl.exe -sS -o NUL -w "%{http_code}" --max-time 25 'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.1.0/kotlin-stdlib-2.1.0.pom' 2>&1
  $lines += ("curl_maven=" + ($r | Out-String))
  $r2 = & curl.exe -sS -o NUL -w "%{http_code}" --max-time 25 'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/8.7.3/gradle-8.7.3.pom' 2>&1
  $lines += ("curl_google=" + ($r2 | Out-String))
} else {
  $lines += "curl.exe not found"
}

Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
