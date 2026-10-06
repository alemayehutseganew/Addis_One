# Rewrites relative imports across the merged tree so each one resolves to the
# file it originally pointed at.
#
# The naive alternative — adding one `../` to every import, because every moved
# file went exactly one level deeper — is wrong. It is only right for imports
# that crossed the old `lib/` boundary. An import from `data/` to its sibling
# `domain/` needs no change at all, and one from a presentation screen up to
# `core/` needs a different number of levels than one from a domain file.
#
# So each import is resolved against the file's *original* location, mapped
# through the merge's rename table, and re-expressed relative to the file's *new*
# location. That is mechanical, and it is the only version of this that can be
# trusted without the analyzer disagreeing about some file nobody looked at.

$ErrorActionPreference = 'Stop'

# ── UTF-8, always ──
#
# These files carry Amharic copy and box-drawing characters. Reading them with
# PowerShell's default encoding and writing them back re-encodes every
# non-ASCII character, so `አማርኛ` silently becomes mojibake — and a test comparing
# against a mangled *expected* string passes while the app renders correct text.
# Every read and write below therefore names UTF-8 explicitly.
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Read-Utf8([string]$path) { [System.IO.File]::ReadAllText($path, $Utf8) }
function Write-Utf8([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $Utf8) }

$apps    = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps'
$dstLib  = Join-Path $apps 'addis_one\lib'

# The source apps' own `lib/` directory, spelled out rather than derived. This
# script never chdir's, but `$lib` is the natural name for it here and reusing it
# for the destination is what previously left the copy below reading from
# `apps\localization.dart` — a path that does not exist, so the copy silently
# failed and the merged app kept the stale strings.
$libDir  = 'lib'

# Everything below works in Windows separators, so paths handed in from
# [System.IO.Path] and paths written into the move tables compare equal. Mixing
# the two is how a rename table silently stops matching anything.
$SEP = '\'

# ── Old path (relative to the source app's lib/) -> new path (relative to
#    addis_one/lib/). Anything unlisted maps to itself, which is how the shared
#    `core/` and `app/` directories keep serving both halves. ──
$passengerMoves = @{
    "features$SEP"                 = "features${SEP}passenger$SEP"
    "core${SEP}models${SEP}validation.dart" = "core${SEP}models${SEP}ticket_validation.dart"
}
$staffMoves = @{
    "features${SEP}auth${SEP}domain${SEP}auth_controller.dart" = "features${SEP}staff${SEP}auth${SEP}domain${SEP}staff_auth_controller.dart"
    "features${SEP}auth${SEP}domain${SEP}auth_state.dart"      = "features${SEP}staff${SEP}auth${SEP}domain${SEP}staff_auth_state.dart"
    "features$SEP"                 = "features${SEP}staff$SEP"
    "core${SEP}models${SEP}validation.dart" = "core${SEP}models${SEP}scan_outcome.dart"
}

# Exact matches first, then longest directory prefix, so `features/auth/...`
# is not swallowed by the `features` prefix rule.
function Resolve-Rel([string]$rel, [hashtable]$moves) {
    if ($moves.ContainsKey($rel)) { return $moves[$rel] }

    foreach ($prefix in ($moves.Keys | Sort-Object Length -Descending)) {
        if (-not $prefix.EndsWith($SEP)) { continue }
        if ($rel.StartsWith($prefix)) {
            return $moves[$prefix] + $rel.Substring($prefix.Length)
        }
    }
    return $rel
}

# Copies one app's tree into the merged app, rewriting imports as it goes.
#
# ## The one rule that governs every import
#
# Each feature file moved exactly one directory deeper — `features/A/…` became
# `features/passenger/A/…` — while `core/` and `app/` did not move at all. So:
#
#  * an import whose target ALSO moved (anything else under `features/`) keeps
#    its relative path exactly, because both ends of the hop went down one level;
#  * an import whose target stayed put (`core/…`, `app/…`) needs one extra
#    `../`, because only the source end got deeper.
#
# That is the whole transformation, and it needs no path arithmetic at all. An
# earlier version tried to resolve each spec to an absolute path and recompute a
# relative one; on Windows that produced silently truncated results
# (`../../app/theme.dart` came back as `../../t`), which is not a mistake an
# analyzer error explains.
function Copy-Rewritten([string]$srcRoot, [string]$subDir, [hashtable]$moves) {
    $src = Join-Path $srcRoot "lib$SEP$subDir"
    if (-not (Test-Path $src)) { return 0 }

    $srcLib = Join-Path $srcRoot 'lib'
    $featuresRoot = Join-Path $srcLib 'features'
    $count  = 0

    Get-ChildItem $src -Recurse -File -Filter *.dart | ForEach-Object {
        $file = $_
        $oldRel = $file.FullName.Substring($srcLib.Length).TrimStart($SEP)

        $newRel = Resolve-Rel $oldRel $moves
        $out = Join-Path $dstLib $newRel
        # Authored files are left alone; this pass only rewrites the copies.
        if (Test-Path $out) { return }

        New-Item -ItemType Directory -Path (Split-Path $out -Parent) -Force | Out-Null

        $newDir = Split-Path $out -Parent
        $text = Read-Utf8 $file.FullName

        # Rewrites one import spec so it resolves from the file's new home.
        #
        # Tries every plausible depth rather than one. The arithmetic above is
        # right for the great majority of imports, but two of the source files
        # carry a depth that was already off by one, and trusting the arithmetic
        # alone would copy the mistake into the merged tree instead of dropping
        # it. Shallower depths are tried first, because the move only ever added
        # levels — never removed them.
        function Resolve-Spec([string]$dir, [string]$spec, [string]$fallback) {
            $candidates = @()
            $s = $spec
            for ($n = 0; $n -le 5; $n++) {
                $candidates += $s
                if ($s.StartsWith('../')) { $s = $s.Substring(3) } else { break }
            }
            for ($n = 1; $n -le 3; $n++) { $candidates += ('../' * $n) + $spec }

            foreach ($c in $candidates) {
                $abs = [System.IO.Path]::GetFullPath(
                    (Join-Path $dir ($c.Replace('/', $SEP))))
                if (Test-Path $abs) { return $c }
            }
            return $fallback
        }

        $text = [regex]::Replace($text, "(?m)^(import\s+')(\.[^']*)(')", {
            param($m)
            $spec = $m.Groups[2].Value

            # Where the target used to live.
            $oldTarget = [System.IO.Path]::GetFullPath(
                (Join-Path $file.DirectoryName ($spec.Replace('/', $SEP))))

            # An import whose target stayed put needs one extra level, because
            # only the source end moved deeper. One that moved with us does not.
            $candidate = $spec
            if (-not $oldTarget.StartsWith($featuresRoot + $SEP)) {
                $candidate = '../' + $spec
            }

            # …and then the candidate is checked against reality. Two of the
            # source files carry a depth that was already off by one, so trusting
            # the arithmetic alone would preserve the mistake rather than fix it.
            $resolved = Resolve-Spec $newDir $candidate $candidate

            return $m.Groups[1].Value + $resolved + $m.Groups[3].Value
        })

        Write-Utf8 $out $text
        $count++
    }
    return $count
}

# Every relative import in the merged tree must resolve. Checked here rather than
# left to the analyzer, because a bad path surfaces as a dozen unrelated
# "undefined name" errors that cost a full analysis cycle to trace back.
function Assert-ImportsResolve([string]$libRoot) {
    $bad = @()
    foreach ($f in (Get-ChildItem $libRoot -Recurse -File -Filter *.dart)) {
        $text = Read-Utf8 $f.FullName
        foreach ($m in [regex]::Matches($text, "(?m)^import '(\.[^']*)'")) {
            $abs = [System.IO.Path]::GetFullPath(
                (Join-Path $f.DirectoryName $m.Groups[1].Value.Replace('/', $SEP)))
            if (-not (Test-Path $abs)) {
                $bad += "  $($f.Name): $($m.Groups[1].Value)"
            }
        }
    }
    if ($bad.Count -gt 0) {
        Write-Output "UNRESOLVED IMPORTS ($($bad.Count)):"
        $bad | Select-Object -First 15 | ForEach-Object { Write-Output $_ }
    } else {
        Write-Output 'all relative imports resolve'
    }
}

# Clear only the copied trees. `features/auth` is authored — it holds the role
# picker — so it is preserved rather than swept with the rest.
foreach ($d in @("features${SEP}passenger", "features${SEP}staff", "core${SEP}models", "core${SEP}widgets")) {
    $p = Join-Path $dstLib $d
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}

# Order matters: `Resolve-Spec` verifies each rewritten import against the merged
# tree, so a target has to exist before the file importing it is written. The
# models are imported from all over the feature trees, so they go first.
# The returned counts are not used for anything, and the assignments only existed
# to satisfy a habit of capturing return values. They also read as if the order
# were meaningful, which invited reordering that is not: `Resolve-Spec` verifies
# each rewritten import against the merged tree, so a target has to exist before
# the file importing it is written, and that is the only ordering constraint.
Copy-Rewritten (Join-Path $apps 'passenger') "core${SEP}models" $passengerMoves
Copy-Rewritten (Join-Path $apps 'staff')    "core${SEP}models" $staffMoves
Copy-Rewritten (Join-Path $apps 'passenger') "core${SEP}widgets" $passengerMoves

Copy-Rewritten (Join-Path $apps 'passenger') 'features' $passengerMoves
Copy-Rewritten (Join-Path $apps 'staff')    'features' $staffMoves

# `localization.dart` and `money.dart` sit directly under `core/` and are used by
# both halves, so they are copied rather than re-rooted under a role. Written with
# an explicit UTF-8 decode: `localization.dart` holds the Amharic strings, and a
# default-encoding read turns them into mojibake that still compiles — the
# damage only surfaces as tests comparing against the wrong characters.
$Utf8 = New-Object System.Text.UTF8Encoding $false
foreach ($name in @('localization.dart', 'money.dart')) {
    $out = Join-Path $dstLib "core$SEP$name"
    [System.IO.File]::WriteAllText(
        $out,
        [System.IO.File]::ReadAllText(
            (Join-Path $apps "passenger$libDir$SEP$name"), $Utf8),
        $Utf8)
    Write-Output "  core/$name (UTF-8)"
}

Assert-ImportsResolve $dstLib