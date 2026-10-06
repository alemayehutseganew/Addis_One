$f = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\scripts\verify-cash-sale.ps1'
$l = [System.IO.File]::ReadAllLines($f)
$out = [System.Collections.Generic.List[string]]::new()

# Drop the misplaced /auth/me block (lines 57..63, 1-based) and re-insert it after
# the $ph header is built. It ran before the header existed, so the request went
# out unauthenticated, 401'd, and left the user id null - which surfaced later as
# a misleading "passengerUserId must be a UUID" from the sale endpoint.
for ($i = 0; $i -lt $l.Count; $i++) {
  $line = $l[$i]
  if ($i -ge 56 -and $i -le 62) { continue }
  $out.Add($line)
  if ($line -match '^\s*\$ph\s*=\s*@\{') {
    $out.Add('')
    $out.Add('      # /auth/verify-otp returns tokens only, so the user id must come')
    $out.Add('      # from /auth/me, which returns AuthenticatedUser ({ id, phone, displayName }).')
    $out.Add('      $me = Invoke-RestMethod "$api/auth/me" -Headers $ph -TimeoutSec 10')
    $out.Add('      $passengerUserId = $me.id')
    $out.Add('      Rep ''passenger id resolved'' ''True'' ($null -ne $passengerUserId)')
  }
}
[System.IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding($false)))
'lines=' + $out.Count