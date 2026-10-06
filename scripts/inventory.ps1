$root = 'c:\Users\alexo\Desktop\File\Code\AddisTransport'
$out  = "$env:TEMP\at_inventory.txt"
$lines = @()
$lines += "=== source files ==="
Get-ChildItem (Join-Path $root 'backend\src') -Recurse -File -Filter '*.ts' -EA SilentlyContinue |
  Sort-Object FullName | ForEach-Object {
    $n = (Get-Content $_.FullName | Measure-Object -Line).Lines
    $lines += ("{0,5}  {1}" -f $n, $_.FullName.Replace("$root\backend\src\",''))
  }
$lines += ""
$lines += "=== totals ==="
$src = Get-ChildItem (Join-Path $root 'backend\src') -Recurse -File -Filter '*.ts'
$lines += ("ts_files=" + ($src|Measure-Object).Count)
$lines += ("test_files=" + ($src | Where-Object { $_.Name -like '*.spec.ts' } | Measure-Object).Count)
$lines += ("impl_files=" + ($src | Where-Object { $_.Name -notlike '*.spec.ts' } | Measure-Object).Count)
$lines += ("total_lines=" + ($src | ForEach-Object { (Get-Content $_.FullName | Measure-Object -Line).Lines } | Measure-Object -Sum).Sum)
Set-Content -Path $out -Value $lines -Encoding UTF8
Write-Output "wrote"
