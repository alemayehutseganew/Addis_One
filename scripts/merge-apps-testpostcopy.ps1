# Post-copy pass over the merged TEST tree.
#
# Tests import by `package:` URI, so unlike `lib/` they need every feature path
# re-rooted under its role: `features/auth/...` became
# `features/passenger/auth/...` and `features/staff/...` gained a `staff` level.
#
# Which half a test came from is decided by the staff-only features it names, not
# by where the file lives — `api_client_test.dart` and `domain_test.dart` came
# from the staff app and are the only ones that reference them. Deciding it that
# way keeps the discriminator correct even if a file is later renamed.
#
# UTF-8 in, UTF-8 out — see the note in `merge-apps-postcopy.ps1`.

$ErrorActionPreference = 'Stop'

$Utf8 = New-Object System.Text.UTF8Encoding $false
function Read-Utf8([string]$p)  { [System.IO.File]::ReadAllText($p, $Utf8) }
function Write-Utf8([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8) }

$test = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps\addis_one\test'
$apps = 'C:\Users\alexo\Desktop\File\Code\AddisTransport\apps'

# ── Re-copy the test sources ──
#
# Done here rather than at the very start of the merge so it is UTF-8 safe. Three
# of these files carry non-ASCII: Amharic digits in the phone-formatting tests
# and box-drawing characters in the label tests. A default-encoding round trip
# re-encodes them, and the failure that surfaces is not a compile error — it is a
# test comparing against a mangled *expected* string, which fails for a reason
# that has nothing to do with the code under test.
#
# The authored tests in this directory are preserved, so only the copied ones are
# replaced.
$authored = @('routing_test.dart', 'role_isolation_test.dart')

foreach ($app in @('passenger', 'staff')) {
    $src = Join-Path $apps "$app\test"
    Get-ChildItem $src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\')
        if ($authored -contains $_.Name) { return }
        $out = Join-Path $test $rel
        New-Item -ItemType Directory -Path (Split-Path $out -Parent) -Force | Out-Null
        # The fixture is data, not code, and has the same encoding requirement.
        Copy-Item $_.FullName $out -Force
    }
}
Write-Output "test sources re-copied as UTF-8"

$staffRoots = @(
    'auth/domain/staff_repository.dart',
    'auth/domain/staff_auth_state.dart',
    'auth/domain/staff_auth_controller.dart',
    'validation/',
    'common/',
    'shifts/'
)

$passengerRoots = @(
    'auth/data/dio_auth_gateway.dart',
    'auth/domain/auth_controller.dart',
    'auth/domain/auth_state.dart',
    'auth/presentation/screens/otp_screen.dart',
    'auth/presentation/screens/phone_entry_screen.dart',
    'home/',
    'journey_planner/',
    'location/',
    'profile/',
    'ticketing/',
    'vehicle_code/'
)

# Symbol renames, split by half for the same reason.
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
    '\bValidationOutcome\b' = 'ScanOutcome'
    '\bparseOutcome\b'      = 'parseScanOutcome'
    '\bValidationRecord\b'  = 'ScanHistoryEntry'
    '\bauthControllerProvider\b' = 'staffAuthControllerProvider'
}

foreach ($file in (Get-ChildItem $test -File -Filter *.dart)) {
    $c = Read-Utf8 $file.FullName

    # The package was renamed when the two apps became one.
    $c = $c.Replace('package:addis_one_passenger/', 'package:addis_one/')
    $c = $c.Replace('package:addis_one_staff/',    'package:addis_one/')

    # Which half?
    $isStaff = $false
    foreach ($r in $staffRoots) {
        if ($c.Contains("addis_one/features/$r")) { $isStaff = $true; break }
    }

    if ($isStaff) {
        foreach ($r in $staffRoots) {
            $c = $c.Replace("addis_one/features/$r", "addis_one/features/staff/$r")
        }
        # The staff half's validation vocabulary was renamed on the way in.
        $c = $c.Replace('addis_one/features/auth/domain/auth_controller.dart',
                        'addis_one/features/staff/auth/domain/staff_auth_controller.dart')
        $c = $c.Replace('addis_one/features/auth/domain/auth_state.dart',
                        'addis_one/features/staff/auth/domain/staff_auth_state.dart')
        $c = $c.Replace('addis_one/core/models/validation.dart',
                        'addis_one/core/models/scan_outcome.dart')
        foreach ($k in $staffRenames.Keys) { $c = $c -replace $k, $staffRenames[$k] }
    } else {
        foreach ($r in $passengerRoots) {
            $c = $c.Replace("addis_one/features/$r", "addis_one/features/passenger/$r")
        }
        $c = $c.Replace('addis_one/core/models/validation.dart',
                        'addis_one/core/models/ticket_validation.dart')
        foreach ($k in $passengerRenames.Keys) { $c = $c -replace $k, $passengerRenames[$k] }
    }

    # `TokenStorage` gained a required `role` in the merge.
    $c = $c.Replace('TokenStorage(storage:', 'TokenStorage(role: AppRole.passenger, storage:')
    $c = $c.Replace('tokens: TokenStorage()', 'tokens: TokenStorage(role: AppRole.passenger)')
    $c = $c.Replace('tokens: _EmptyTokenStorage()', 'tokens: _EmptyTokenStorage(role: AppRole.staff)')

    # …and so did the local fake that stands in for it. A fake that quietly
    # accepted any role would let a test assert against the wrong credential
    # namespace and still pass, which is the one thing the namespace exists to
    # prevent.
    $c = $c.Replace(
        "class _EmptyTokenStorage implements TokenStorage {`r`n  @override`r`n  Future<String?> get accessToken async => null;",
        "class _EmptyTokenStorage implements TokenStorage {`r`n  _EmptyTokenStorage({required this.role});`r`n`r`n  @override`r`n  final AppRole role;`r`n`r`n  @override`r`n  Future<String?> get accessToken async => null;")
    $c = $c.Replace(
        "class _EmptyTokenStorage implements TokenStorage {`n  @override`n  Future<String?> get accessToken async => null;",
        "class _EmptyTokenStorage implements TokenStorage {`n  _EmptyTokenStorage({required this.role});`n`n  @override`n  final AppRole role;`n`n  @override`n  Future<String?> get accessToken async => null;")

    # …which means the tests naming it need the type in scope.
    if ($c -match 'AppRole\.' -and -not $c.Contains("import 'package:addis_one/core/auth/app_role.dart';")) {
        $anchor = "import 'package:addis_one/core/models/journey_plan.dart';"
        $line   = "import 'package:addis_one/core/auth/app_role.dart';"
        if ($c.Contains($anchor)) {
            $c = $c.Replace($anchor, "$line`r`n$anchor")
        } else {
            $anchor2 = "import 'package:addis_one/core/models/staff_session.dart';"
            if ($c.Contains($anchor2)) {
                $c = $c.Replace($anchor2, "$line`r`n$anchor2")
            } else {
                $anchor3 = "import 'package:addis_one/core/storage/token_storage.dart';"
                if ($c.Contains($anchor3)) {
                    $c = $c.Replace($anchor3, "$line`r`n$anchor3")
                }
            }
        }
    }

    # The 401 suite exercises the *passenger* policy, which is the one that
    # refreshes. The flag is explicit rather than implied because the merged app
    # has two policies on purpose: a passenger may be refreshed silently, a staff
    # session may not, since a scan retried against a stale session could be
    # recorded against the wrong officer. A test that got the refresh behaviour
    # without asking for it would pass for the wrong reason.
    $c = $c.Replace(
        "    final api = ApiClient(tokens: tokens, baseUrl: baseUrl);`r`n    api.onUnauthorized",
        "    final api = ApiClient(`r`n      tokens: tokens,`r`n      baseUrl: baseUrl,`r`n      refreshOnUnauthorized: true,`r`n    );`r`n    api.onUnauthorized")
    $c = $c.Replace(
        "    final api = ApiClient(tokens: tokens, baseUrl: baseUrl);`r`n    var hookCalls = 0;",
        "    final api = ApiClient(`r`n      tokens: tokens,`r`n      baseUrl: baseUrl,`r`n      refreshOnUnauthorized: true,`r`n    );`r`n    var hookCalls = 0;")

    # The merged app namespaces every credential by role, so the seeded keys moved
    # with everything else. Left unprefixed, the store reads nothing, `hasSession`
    # is false, and the whole suite fails on a setup detail rather than on the
    # behaviour it exists to pin.
    $c = $c.Replace("'addis_one_access_token'", "'addis_one_passenger_access_token'")
    $c = $c.Replace("'addis_one_refresh_token'", "'addis_one_passenger_refresh_token'")

    # The suite above only ever exercises the passenger policy, so on its own it
    # would leave the staff half's half of the contract untested — and that is the
    # half where getting it wrong writes a scan against the wrong officer.
    $staffGroup = @"

  group('the staff half is NOT refreshed silently', () {
    // The two halves share one ApiClient class but not one policy. An officer
    // whose token expires mid-shift must be told, because a scan silently
    // retried against a stale session could be recorded against the wrong
    // officer.
    ApiClient clientWithoutRefresh(TokenStorage tokens) =>
        ApiClient(tokens: tokens, baseUrl: baseUrl);

    test('a 401 surfaces instead of being retried', () async {
      final tokens = seededTokens();

      await expectLater(
        clientWithoutRefresh(tokens).getJson('/validation/scan'),
        throwsA(isA<ApiException>()
            .having((e) => e.failure, 'failure', ApiFailure.unauthorized)),
      );

      // Nothing was refreshed, so the server never saw a second request.
      expect(refreshCalls, 0);
    });

    test('the stored credential is left untouched', () async {
      // A refresh rotates the token, so silently performing one would replace an
      // officer's credential with a fresh pair they never asked for.
      final tokens = seededTokens();

      await expectLater(
        clientWithoutRefresh(tokens).getJson('/validation/scan'),
        throwsA(isA<ApiException>()),
      );

      expect(await tokens.accessToken, 'stale-access');
      expect(await tokens.refreshToken, 'refresh-original');
    });
  });
}
"@.Replace("`n", "`r`n")

    $tail = "    expect(refreshCalls, 1);`r`n  });`r`n}"
    if ($c.Contains($tail) -and -not $c.Contains('the staff half is NOT refreshed')) {
        $c = $c.Replace($tail, "    expect(refreshCalls, 1);`r`n  });`r`n$staffGroup")
    }

    # This file is the only one that must not import the repository *and* the
    # shared failure file. Elsewhere the repository is the sole import and also
    # supplies `TransportRepository`, `NearbyStop` and friends, so removing it
    # there takes the type with it.
    $repoImport = "import 'package:addis_one/features/passenger/journey_planner/domain/transport_repository.dart';"
    if ($file.Name -eq 'api_client_401_test.dart' -and $c.Contains($repoImport)) {
        $c = $c.Replace("$repoImport`r`n", '').Replace("$repoImport`n", '')
    }

    # …and the shared import is guaranteed rather than assumed. A test that
    # references the failure vocabulary and does not import it fails to compile
    # with "isn't a type", which says nothing about where the import went.
    $usesFailure = $c -match '\bApiException\b' -or $c -match '\bApiFailure\b'
    $hasFailure = $c.Contains("import 'package:addis_one/core/network/api_failure.dart';")
    if ($usesFailure -and -not $hasFailure) {
        $anchor = "import 'package:addis_one/core/models/journey_plan.dart';"
        if ($c.Contains($anchor)) {
            $c = $c.Replace($anchor, "import 'package:addis_one/core/network/api_failure.dart';`r`n$anchor")
        } else {
            $anchor2 = "import 'package:addis_one/core/money.dart';"
            if ($c.Contains($anchor2)) {
                $c = $c.Replace($anchor2, "import 'package:addis_one/core/network/api_failure.dart';`r`n$anchor2")
            } else {
                $anchor3 = "import 'package:flutter_test/flutter_test.dart';"
                $c = $c.Replace($anchor3, "import 'package:addis_one/core/network/api_failure.dart';`r`n$anchor3")
            }
        }
    }

    # The shared failure import is only redundant when the repository — which
    # re-exports it — is imported too. Removing it unconditionally would take
    # `TransportRepository` and `NearbyStop` with it.
    $hasRepo = $c.Contains("transport_repository.dart';")
    if ($hasRepo) {
        $c = $c.Replace("import 'package:addis_one/core/network/api_failure.dart';`r`n", '')
        $c = $c.Replace("import 'package:addis_one/core/network/api_failure.dart';`n", '')
    } else {
        # The "already has it" case is skipped by the collapse above, so a file
        # that reached this pass twice keeps a duplicate `offline`. Neither is a
        # compile error — an unreachable switch case is only a warning — so it is
        # cleaned here rather than left to be rediscovered.
        $c = $c.Replace(
            "        ApiFailure.offline => 'No connection. The scan was saved locally.',`r`n        ApiFailure.cancelled => 'Cancelled.',`r`n        ApiFailure.offline => 'No connection. The scan was saved locally.',",
            "        ApiFailure.offline => 'No connection. The scan was saved locally.',`r`n        ApiFailure.cancelled => 'Cancelled.',")
        $c = $c.Replace(
            "      case ApiFailure.cancelled:`r`n      case ApiFailure.offline:`r`n        return false;",
            "      case ApiFailure.cancelled:`r`n        return false;")
    }

    Write-Utf8 $file.FullName $c
}

Write-Output 'test pass complete'