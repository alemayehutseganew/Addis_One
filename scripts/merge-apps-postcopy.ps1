# Post-copy pass over the merged tree: rename the symbols that collided, then
# apply the semantic repairs the merge forced.
#
# Run once after `merge-apps-imports.ps1`. Every substitution here is idempotent
# *by construction* — the patterns only match the pre-merge spelling — so a
# re-run over already-processed files is a no-op rather than a second
# application. That matters: an earlier version of this script was not
# idempotent and duplicated the `ApiFailure` cases it added.
#
# UTF-8 in, UTF-8 out. These trees carry Amharic copy and box-drawing
# characters; a default-encoding round trip re-encodes every one of them, and a
# test comparing against a mangled expected string then passes while the app
# renders correct text.

$ErrorActionPreference = 'Stop'

$Utf8 = New-Object System.Text.UTF8Encoding $false
function Read-Utf8([string]$p)  { [System.IO.File]::ReadAllText($p, $Utf8) }
function Write-Utf8([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8) }

$root = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one'
$lib  = Join-Path $root 'lib'
$pax  = Join-Path $lib 'features\passenger'
$staff = Join-Path $lib 'features\staff'

# ── 1. Passenger sign-in types gain a role prefix ──
#
# The staff half declares `AuthState` and `AuthController` with entirely
# different meanings. One package, one name each, so one side has to move.
$passengerRenames = [ordered]@{
    '\bAuthController\b'     = 'PassengerAuthController'
    '\bAuthState\b'         = 'PassengerAuthState'
    '\bAuthUnknown\b'       = 'PassengerAuthUnknown'
    '\bAuthPhoneEntered\b'  = 'PassengerAuthPhoneEntered'
    '\bAuthOtpSent\b'       = 'PassengerAuthOtpSent'
    '\bAuthVerifying\b'     = 'PassengerAuthVerifying'
    '\bAuthAuthenticated\b' = 'PassengerAuthAuthenticated'
    '\bAuthFailure\b'       = 'PassengerAuthFailure'
    '\bauthControllerProvider\b' = 'passengerAuthControllerProvider'
    '\bauthStateProvider\b'      = 'passengerAuthStateProvider'
    '\bisSignedInProvider\b'     = 'isPassengerSignedInProvider'
}

$staffRenames = [ordered]@{
    '\bAuthController\b' = 'StaffAuthController'
    '\bAuthState\b'     = 'StaffAuthState'
    '\bAuthStage\b'     = 'StaffAuthStage'
    '\bValidationOutcome\b'            = 'ScanOutcome'
    '\bparseOutcome\b'                 = 'parseScanOutcome'
    '\bValidationOutcomePresentation\b' = 'ScanOutcomePresentation'
    '\bValidationOutcomeBoarding\b'     = 'ScanOutcomeBoarding'
    '\bValidationRecord\b'              = 'ScanHistoryEntry'
    '\bauthControllerProvider\b'         = 'staffAuthControllerProvider'
}

function Apply([string]$dir, [System.Collections.IDictionary]$map, [string]$label) {
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem $dir -Recurse -File -Filter *.dart | ForEach-Object {
        $c = Read-Utf8 $_.FullName
        $before = $c
        foreach ($k in $map.Keys) { $c = $c -replace $k, $map[$k] }
        if ($c -ne $before) {
            Write-Utf8 $_.FullName $c
            Write-Output "  $label -> $($_.Name)"
        }
    }
}

Apply $pax  $passengerRenames 'passenger'
Apply $staff $staffRenames    'staff'

# ── 1b. The staff half's wire vocabulary, which moved out of the feature tree ──
#
# `ValidationOutcome` was a sealed class in the passenger half and an enum in the
# staff half: the same name, incompatible types, in one package. The staff one is
# renamed to `ScanOutcome` and its history model to `ScanHistoryEntry`.
$scanOutcome = Join-Path $lib 'core\models\scan_outcome.dart'
$c = Read-Utf8 $scanOutcome
$c = $c -replace '\bValidationOutcome\b', 'ScanOutcome'
$c = $c -replace '\bparseOutcome\b', 'parseScanOutcome'
$c = $c -replace '\bValidationOutcomeBoarding\b', 'ScanOutcomeBoarding'
$c = $c -replace '\bValidationRecord\b', 'ScanHistoryEntry'
Write-Utf8 $scanOutcome $c

# ── 1c. The duty screen ──
#
# Renamed only because the passenger half has its own `TripsScreen` and the two
# are unrelated; `StaffDutyScreen` names which one the router means.
$duty = Join-Path $staff 'duty\presentation\screens\duty_screen.dart'
$c = Read-Utf8 $duty
$c = $c -replace '\bDutyScreen\b', 'StaffDutyScreen'
Write-Utf8 $duty $c

# ── 2. Theme: `StaffTheme` became a palette inside the single `app/theme.dart` ──
#
# Two ThemeDatas in one binary would mean a visible style change at the role
# boundary, which is precisely what this merge exists to remove. The colours are
# preserved one-for-one; only the mechanism for reaching them changed.
$themeMap = [ordered]@{
    'StaffTheme.greenDark' = 'StaffColors.greenDark'
    'StaffTheme.green'     = 'StaffColors.green'
    'StaffTheme.refuse'    = 'AppColors.verdictRefuse'
    'StaffTheme.unknown'   = 'AppColors.verdictUnknown'
    'StaffTheme.inkMuted'  = 'AppColors.inkMuted'
    'StaffTheme.ink'       = 'AppColors.ink'
    'StaffTheme.accept'    = 'AppColors.verdictAccept'
    'StaffTheme.surface'   = 'AppColors.surface'
}

# The `ScanOutcome` rename does not reach theme.dart, because that file is
# authored rather than copied — it is handled explicitly here.
$themeFile = Join-Path $lib 'app\theme.dart'
$c = Read-Utf8 $themeFile
foreach ($k in $themeMap.Keys) { $c = $c.Replace($k, $themeMap[$k]) }
Write-Utf8 $themeFile $c

# ── 3. Semantic repairs the merge forced ──

# 3a. Routes are now namespaced by role.
Get-ChildItem $lib -Recurse -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    $c = $c -replace 'Routes\.home\b', 'Routes.passengerHome'
    if ($c -ne $before) { Write-Utf8 $_.FullName $c }
}

# 3b. The merged `ApiFailure` is the union of both original enums, so switches
#     that were exhaustive against one of them are no longer exhaustive.
#
# `timeout` and `unknown` arrived with the passenger half. Neither is a distinct
# thing to say to an officer at a bus door: both mean "the call did not settle",
# which the generic server message already covers.
#
# Each pattern below matches the *pristine* source and rewrites it to the
# exhaustive form. Because the replacement no longer contains the pattern, the
# pass is idempotent. An earlier version anchored on the already-expanded text
# instead, which meant it matched nothing and the cases were silently never
# added — a rewrite that reads as correct and does nothing.
#
# The replacement puts the merged-only members (`timeout`, `unknown`) next to
# `server`, which already said the same thing, rather than inventing a fourth
# message for each.
$caseAdds = @(
    @(
        ("        ApiFailure.server => 'The server had a problem. Try again shortly.',`r`n" +
         "        ApiFailure.cancelled => 'Cancelled.',`r`n" +
         "        ApiFailure.offline => 'No connection. The scan was saved locally.',"),
        ("        ApiFailure.server => 'The server had a problem. Try again shortly.',`r`n" +
         "        ApiFailure.timeout => 'The server had a problem. Try again shortly.',`r`n" +
         "        ApiFailure.unknown => 'The server had a problem. Try again shortly.',`r`n" +
         "        ApiFailure.cancelled => 'Cancelled.',`r`n" +
         "        ApiFailure.offline => 'No connection. The scan was saved locally.',")
    ),
    @(
        ("      case ApiFailure.server:`r`n      case ApiFailure.cancelled:`r`n      case ApiFailure.offline:"),
        ("      case ApiFailure.server:`r`n" +
         "      case ApiFailure.timeout:`r`n" +
         "      case ApiFailure.unknown:`r`n" +
         "      case ApiFailure.cancelled:`r`n" +
         "      case ApiFailure.offline:")
    )
)

Get-ChildItem $lib -Recurse -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    foreach ($pair in $caseAdds) { $c = $c.Replace($pair[0], $pair[1]) }
    if ($c -ne $before) { Write-Utf8 $_.FullName $c }
}

# 3c. `StaffTheme` became a palette inside the single `app/theme.dart`.
#
# Applied across the whole staff tree, not just the theme file: keeping two
# ThemeDatas in one binary would mean a visible style change at the role
# boundary, which is precisely what this merge exists to remove. The colours are
# preserved one-for-one; only the mechanism for reaching them changed.
$staffThemeMap = [ordered]@{
    'StaffTheme.greenDark' = 'StaffColors.greenDark'
    'StaffTheme.green'     = 'StaffColors.green'
    'StaffTheme.refuse'    = 'AppColors.verdictRefuse'
    'StaffTheme.unknown'   = 'AppColors.verdictUnknown'
    'StaffTheme.inkMuted'  = 'AppColors.inkMuted'
    'StaffTheme.ink'       = 'AppColors.ink'
    'StaffTheme.accept'    = 'AppColors.verdictAccept'
    'StaffTheme.surface'   = 'AppColors.surface'
}
Get-ChildItem $staff -Recurse -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    foreach ($k in $staffThemeMap.Keys) { $c = $c.Replace($k, $staffThemeMap[$k]) }
    if ($c -ne $before) { Write-Utf8 $_.FullName $c }
}

# 3d. The staff controller's provider now lives in the shared composition root,
#     where the role has to be in scope. Left in place it would be declared twice
#     in the same package, and the name would resolve to whichever the analyzer
#     happened to see last.
$staffController = Join-Path $staff 'auth\domain\staff_auth_controller.dart'
$c = Read-Utf8 $staffController
$c = [regex]::Replace($c, "(?s)\r?\nfinal staffAuthControllerProvider\s*=.*?\n\}\);\s*$", "`r`n")
$c = $c.Replace("import '../../../../app/providers.dart';`r`n", "")
$c = $c.Replace("import '../../../../app/providers.dart';`n", "")
Write-Utf8 $staffController $c

# The auth gateway's own switch, which has a different shape from the staff one:
# no per-case message, so the shared patterns above do not reach it. `offline`
# has to land somewhere — a queued scan has no business in the passenger OTP
# flow, so it is reported as an unknown failure rather than a network one, which
# would tell the passenger to check their connection when the problem is not
# theirs.
$gateway = Join-Path $pax 'auth\data\dio_auth_gateway.dart'
if (Test-Path $gateway) {
    $c = Read-Utf8 $gateway
    $from = "      case ApiFailure.timeout:`r`n      case ApiFailure.cancelled:`r`n      case ApiFailure.unknown:"
    $to   = "      case ApiFailure.timeout:`r`n      case ApiFailure.offline:`r`n      case ApiFailure.cancelled:`r`n      case ApiFailure.unknown:"
    if ($c.Contains($from)) {
        $c = $c.Replace($from, $to)
        Write-Utf8 $gateway $c
        Write-Output '  failure case -> dio_auth_gateway.dart'
    }
}

# ── 1d. Sibling imports inside `core/models/` and the staff auth domain ──
#
# These import by bare filename, so no path-mapping rule in the copy pass can
# catch them — the import resolves relative to the file, not to `lib/`.
Get-ChildItem (Join-Path $lib 'core\models') -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    $c = $c.Replace("import 'validation.dart';", "import 'ticket_validation.dart';")
    if ($c -ne $before) {
        Write-Utf8 $_.FullName $c
        Write-Output "  sibling import -> $($_.Name)"
    }
}

Get-ChildItem (Join-Path $staff 'auth\domain') -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    $c = $c.Replace("import 'auth_state.dart';", "import 'staff_auth_state.dart';")
    $c = $c.Replace("import 'auth_controller.dart';", "import 'staff_auth_controller.dart';")
    if ($c -ne $before) {
        Write-Utf8 $_.FullName $c
        Write-Output "  sibling import -> $($_.Name)"
    }
}

# ── 1e. Route constants renamed by the role namespace ──
#
# `/otp` became `/passenger/otp` and `/sign-in` became `/passenger/sign-in`, so
# the constants carrying those values were renamed to match.
Get-ChildItem $lib -Recurse -File -Filter *.dart | ForEach-Object {
    $c = Read-Utf8 $_.FullName
    $before = $c
    $c = $c -replace 'Routes\.otp\b',         'Routes.passengerOtp'
    $c = $c -replace 'Routes\.otpName\b',    'Routes.passengerOtpName'
    $c = $c -replace 'Routes\.signInName\b', 'Routes.passengerSignInName'
    if ($c -ne $before) {
        Write-Utf8 $_.FullName $c
        Write-Output "  route constant -> $($_.Name)"
    }
}

# ── 1f. `core/widgets/empty_state.dart` sits two levels below `lib/`, so the
#     original's four-level `../../../../` would climb past the package root.
$emptyState = Join-Path $lib 'core\widgets\empty_state.dart'
$c = Read-Utf8 $emptyState
$c = $c.Replace("import '../../../../app/theme.dart';", "import '../../app/theme.dart';")
Write-Utf8 $emptyState $c

# ── 1g. Import paths to the renamed files ──
#
# Matching on the bare filename rather than the full path, so it is independent
# of how deep the importing file happens to sit. The symbol renames above are
# not enough on their own: a file that imports `validation.dart` still points at
# a file that no longer exists under that name.
# Import paths to the renamed files.
#
# Literal string replacement, not regex. A regex anchored on the bare filename
# also matches *inside* an already-renamed path — `validation.dart` is a
# substring of `ticket_validation.dart` — so a second run would produce
# `ticket_ticket_validation.dart`. Matching the whole quoted spec means the
# thing being replaced is unambiguous, and this pass becomes idempotent by
# construction rather than by careful anchoring.
#
# Depth is left alone here: the file at the new depth is the same one the old
# depth pointed at, and `Repair-ImportDepth` below trims the surplus.

$Utf8 = New-Object System.Text.UTF8Encoding $false
function Read-Utf8([string]$p)  { [System.IO.File]::ReadAllText($p, $Utf8) }
function Write-Utf8([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8) }

# Path separator used by the string operations below. Defining it here matters:
# with `$SEP` undefined, `Replace('/', $SEP)` stripped the separators instead of
# normalising them, every path failed to resolve, and the depth-repair pass
# quietly did nothing.
$SEP = '\'

$paxImportMap = [ordered]@{
    'core/models/validation.dart' = 'core/models/ticket_validation.dart'
}
$staffImportMap = [ordered]@{
    'core/models/validation.dart'     = 'core/models/scan_outcome.dart'
    'domain/auth_controller.dart'     = 'domain/staff_auth_controller.dart'
    'domain/auth_state.dart'          = 'domain/staff_auth_state.dart'
}

function Rewrite-Imports([string]$dir, [System.Collections.IDictionary]$map) {
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem $dir -Recurse -File -Filter *.dart | ForEach-Object {
        $c = Read-Utf8 $_.FullName
        $before = $c
        foreach ($k in $map.Keys) {
            $c = $c.Replace($k, $map[$k])
        }
        if ($c -ne $before) {
            Write-Utf8 $_.FullName $c
            Write-Output "  import path -> $($_.Name)"
        }
    }
}

Rewrite-Imports $pax   $paxImportMap
Rewrite-Imports $staff $staffImportMap

# ── 1h. Final resolution sweep ──
#
# Everything above rewrites imports by name. This last pass fixes the *depth* of
# any import still pointing at nothing: the file it named was renamed, so the
# depth chosen for the old name no longer applies, and the only reliable test is
# whether the path resolves.
function Repair-ImportDepth([string]$root) {
    if (-not (Test-Path $root)) { return }
    $fixed = 0

    # Two passes: repairing one file's import can be what makes another's target
    # resolvable, and a single sweep would then report a false failure.
    for ($pass = 0; $pass -lt 2; $pass++) {
        foreach ($f in (Get-ChildItem $root -Recurse -File -Filter *.dart)) {
            $text = Read-Utf8 $f.FullName
            $out = $text

            foreach ($m in [regex]::Matches($text, "(?m)^import '(\.[^']*)'")) {
                $spec = $m.Groups[1].Value
                try {
                    $abs = [System.IO.Path]::GetFullPath(
                        (Join-Path $f.DirectoryName $spec.Replace('/', $SEP)))
                } catch { continue }

                if (Test-Path $abs) { continue }

                # Both directions. A renamed target usually needs one level
                # *fewer*; an import inserted from a fixed guess usually needs one
                # *more*. Trying only "fewer" leaves the second kind broken while
                # reporting no failure, which is the worst of both.
                $candidates = @()
                $s = $spec
                for ($n = 0; $n -le 5; $n++) {
                    $candidates += $s
                    if ($s.StartsWith('../')) { $s = $s.Substring(3) } else { break }
                }
                for ($n = 1; $n -le 4; $n++) { $candidates += ('../' * $n) + $spec }

                $replacement = $null
                foreach ($cand in $candidates) {
                    try {
                        $try = [System.IO.Path]::GetFullPath(
                            (Join-Path $f.DirectoryName $cand.Replace('/', $SEP)))
                    } catch { continue }
                    if (Test-Path $try) { $replacement = $cand; break }
                }

                if ($replacement) {
                    $out = $out.Replace("'$spec'", "'$replacement'")
                }
            }

            if ($out -ne $text) {
                Write-Utf8 $f.FullName $out
                $fixed++
                Write-Output "  depth repaired -> $($f.Name)"
            }
        }
    }
    Write-Output "  depth repairs: $fixed"
}

# ── 1i. Screens that read the shared composition root ──
#
# The staff duty screen reads the sign-in controller, which now lives in
# `app/providers.dart` rather than beside its own controller. Previously it
# reached the controller directly; the provider is declared in one place so the
# role can be in scope, and these screens have to import it from there.
$needsProviders = @(
    'duty\presentation\screens\duty_screen.dart',
    'validation\presentation\screens\scan_screen.dart',
    'auth\presentation\screens\sign_in_screen.dart'
)
foreach ($rel in $needsProviders) {
    $path = Join-Path $staff $rel
    if (-not (Test-Path $path)) { continue }
    $c = Read-Utf8 $path
    if (-not $c.Contains('staffAuthControllerProvider')) { continue }

    # Any number of the import is collapsed to one, then a single copy is put
    # above the first relative import. Deliberately run even when one is already
    # present, so a previous run that inserted several leaves exactly one behind.
    #
    # The depth is a guess: `Repair-ImportDepth` below corrects it, which is
    # cheaper than working out the right number of `../` per file by hand and
    # getting one wrong.
    $c = $c -replace "(?m)^(import '(\.\./)+app/providers\.dart';\r?\n)+", ""

    # Insert exactly once. A plain [regex]::Replace hits *every* relative import
    # line, which is how a single screen ended up with five copies of the same
    # import.
    #
    # The flag lives in a hashtable rather than a plain `$done`, because assigning
    # to a variable inside a scriptblock creates a *new* variable in that
    # block's scope — the guard would never become true and every import line
    # would still be matched. Mutating an object is visible either way.
    $guard = @{ inserted = $false }
    $c = [regex]::Replace($c, "(?m)^(import '\.\./)", {
        param($m)
        if ($guard.inserted) { return $m.Value }
        $guard.inserted = $true
        return "import '../app/providers.dart';`r`n$($m.Value)"
    })

    # The controller itself is no longer imported here: the provider it used to
    # declare moved to the composition root, and these screens reach it from
    # there. Left behind, it is an unused import — and a second declaration of the
    # same provider name in one package would be worse than that.
    #
    # Matched on the filename alone: the three screens sit at different depths, so
    # a fixed prefix would need three patterns and would still miss one.
    $c = $c -replace "(?m)^import '[^']*auth_controller\.dart';\r?\n", ""

    Write-Utf8 $path $c
    Write-Output "  providers import -> $([System.IO.Path]::GetFileName($rel))"
}
# ── 1k. `prefer_initializing_formals` ──
#
# Several staff classes take a public parameter and assign it to a private field.
# That is deliberate everywhere it appears: callers name a dependency, not an
# implementation detail, and an initializing formal would force the private name
# into every call site. The ignore comment is placed above the *initializer*
# rather than the parameter because that is where the analyzer reports the lint —
# on the original, the comment sat above the parameter and did not suppress it.
$initializerFixes = @(
    @('features\staff\auth\domain\staff_auth_controller.dart',
      "  })  : _repo = repo,`r`n        _tokens = tokens,`r`n        _submitter = submitter,",
      "  })  :`r`n        // ignore: prefer_initializing_formals`r`n        _repo = repo,`r`n        // ignore: prefer_initializing_formals`r`n        _tokens = tokens,`r`n        // ignore: prefer_initializing_formals`r`n        _submitter = submitter,"),

    @('features\staff\auth\domain\staff_repository.dart',
      "  })  : _api = api,`r`n        _tokens = tokens;",
      "  })  :`r`n        // ignore: prefer_initializing_formals`r`n        _api = api,`r`n        // ignore: prefer_initializing_formals`r`n        _tokens = tokens;"),

    @('features\staff\validation\data\scan_queue.dart',
      "  }) : _prefs = prefs;",
      "  })  :`r`n        // ignore: prefer_initializing_formals`r`n        _prefs = prefs;"),

    @('features\staff\validation\data\scan_submitter.dart',
      "  })  : _repo = repo,`r`n        _queue = queue;",
      "  })  :`r`n        // ignore: prefer_initializing_formals`r`n        _repo = repo,`r`n        // ignore: prefer_initializing_formals`r`n        _queue = queue;")
)

foreach ($fix in $initializerFixes) {
    $path = Join-Path $lib $fix[0]
    if (-not (Test-Path $path)) { continue }
    $c = Read-Utf8 $path
    if ($c.Contains($fix[1])) {
        $c = $c.Replace($fix[1], $fix[2])
        Write-Utf8 $path $c
        Write-Output "  lint -> $([System.IO.Path]::GetFileName($fix[0]))"
    }
}

# ── 1l. One `ApiException`, not two ──
#
# The passenger repository used to declare `ApiFailure` and `ApiException` itself.
# The staff half declared its own, and the merged `core/network/api_failure.dart`
# is the union of both — so the local declarations have to go, or the package
# ends up with two classes of the same name.
#
# The failure this causes is quiet and expensive. A test importing both the
# repository and the shared failure file sees *two* `ApiException` types; the one
# `ApiClient` throws is not the one `isA<ApiException>()` resolves to, and every
# such assertion fails with "threw ApiException which is not an instance of
# ApiException" — a message that reads like a type-system bug rather than a
# duplicate declaration.
$transportRepo = Join-Path $pax 'journey_planner\domain\transport_repository.dart'
if (Test-Path $transportRepo) {
    $c = Read-Utf8 $transportRepo
    $before = $c

    # Drop the local enum and class, back to and including their `toString`.
    $c = [regex]::Replace(
        $c,
        '(?s)// Errors the UI can act on\..*?String toString\(\) => .*?\r?\n\}\r?\n\r?\n',
        '')
    $c = [regex]::Replace(
        $c,
        '(?s)// Errors the UI can act on\..*?String toString\(\) => .*?\n\}\n\n',
        '')

    if ($c -ne $before) {
        # Re-export instead, so existing importers of the repository still see
        # the failure vocabulary they always did.
        $c = [regex]::Replace(
            $c,
            "(?m)^import '\.\./\.\./\.\./\.\./core/models/journey\.dart';",
            "// `ApiFailure` and `ApiException` now live in `core/network/api_failure.dart`,`r`n" +
            "// which is the union of both apps' vocabularies. Re-exported here so`r`n" +
            "// existing importers of this repository keep seeing them.`r`n" +
            "export '../../../../core/network/api_failure.dart';`r`n`r`n" +
            "import '../../../../core/models/journey.dart';")

        # The removal above consumed one slash of the doc comment it stopped at.
        $c = $c.Replace('//// Contract for everything', '/// Contract for everything')

        Write-Utf8 $transportRepo $c
        Write-Output '  failure types -> transport_repository.dart'
    }
}

# Runs last, so it also corrects the depth of the import added by 1i above.
# Putting it earlier would leave that one import unverified.
Repair-ImportDepth $lib

Write-Output 'post-copy pass complete'