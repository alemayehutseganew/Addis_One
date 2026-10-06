# Addis One

One Flutter application serving **both** roles in the system: the passenger who
plans a journey and presents a ticket QR, and the staff member who scans it.

This package replaced two separate apps, `addis_one_passenger` and
`addis_one_staff`. They remain in this repository as the merge's source of truth
until the single app is signed off; nothing in `lib/` imports them.

## The role fork

```
                          ADDIS ONE
                       SINGLE FLUTTER APP
                              │
                    ┌─────────┴─────────┐
                    │                   │
              LOGIN / OTP          STAFF LOGIN
                    │                   │
                    ▼                   ▼
             ┌────────────┐     ┌──────────────┐
             │  PASSENGER │     │    STAFF     │
             │    ROLE    │     │     ROLE     │
             └────────────┘     └──────────────┘
```

`/` opens the picker. Everything below it is namespaced by role, and the router
refuses to let one half reach the other's screens.

## Layout

```
lib/
├── main.dart                    one entry point
├── app/
│   ├── app.dart                 root widget; owns locale, role, router
│   ├── router.dart              role-namespaced route table + redirect guard
│   ├── providers.dart           composition root for BOTH roles
│   └── theme.dart               one theme; staff verdict palette included
├── core/
│   ├── auth/app_role.dart       the fork itself
│   ├── config/app_config.dart   union of both apps' build flags
│   ├── network/                 one ApiClient, one ApiFailure
│   ├── storage/                 role-scoped secure token storage
│   └── models/                  passenger + staff wire models
└── features/
    ├── auth/                    the role picker
    ├── passenger/               journeys, ticketing, vehicle codes
    └── staff/                   scanning, trips, shifts, admin, reports
```

## Three decisions the merge forced

**One `TokenStorage`, scoped by role.** The two apps each had an unambiguous
token. One binary does not: a single unqualified key would have one slot for
"the current token", and the halves would fight over it. The role is a
constructor argument, and keys are `addis_one_<role>_…`, so a passenger token
can never be presented to a privileged staff route.

**One `ApiClient`, two policies.** The passenger client refreshed a 401 and
retried silently; the staff client deliberately did not, because a scan silently
retried against a stale session could be recorded against the wrong officer.
That difference is now the `refreshOnUnauthorized` flag, set per role by the
composition root — stated once instead of implied by which class you got.

**Routes namespaced by role.** `/tickets` used to mean one thing because there
were two binaries. Now every route lives under `/passenger/…` or `/staff/…`, and
`roleRedirect` bounces anyone who crosses over. That is not tidiness: without it
the staff repositories would send a passenger bearer token to a privileged route
and the resulting 403 would name a passenger in the audit trail.

## Build

```bash
flutter pub get
flutter run

# Live server (default: the Android emulator's host loopback)
flutter build apk --release

# Point at a deployed environment
flutter build apk --dart-define=API_BASE_URL=https://api.addis.one

# Bundled demo data for the passenger half only.
# Staff surfaces are never faked — an inspector shown an invented verdict is
# worse than one shown no scanner at all.
flutter build apk --dart-define=USE_DEMO_DATA=true

# Offer the OTP-bypass control. Never for a real deployment.
flutter build apk --dart-define=ENABLE_DEV_SIGN_IN=true
```

## Test

```bash
flutter test
```

Or through the repo scripts, which write a report and are safe to run
detached:

```powershell
scripts/analyze-addis-one.ps1
scripts/test-addis-one.ps1
```

`routing_test.dart` carries the role-boundary assertions — that no route is
reachable before a role is chosen, and that each half is bounced out of the
other. Those are cheap tests guarding a real boundary.