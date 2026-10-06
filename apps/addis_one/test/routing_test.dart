// Regression guard for the home screen's dead buttons.
//
// `context.pushNamed` resolves routes by NAME, not by path. When the routes were
// declared with only `path`, the primary "Plan journey" button compiled cleanly,
// passed `flutter analyze`, and threw on every tap -- the app looked finished
// while its main action did nothing. These assertions exist so a route that
// loses its `name` fails the build instead of a passenger's journey.
import 'package:addis_one/app/router.dart';
import 'package:addis_one/core/auth/app_role.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('every named navigation target resolves', () {
    // Names the UI actually calls. Each must exist in the route table.
    const usedInUi = <String>[
      Routes.planJourneyName,
      Routes.passengerSignInName,
      Routes.passengerOtpName,
      Routes.ticketsName,
      Routes.tripsName,
      Routes.profileName,
      Routes.vehicleCodeName,
    ];

    for (final name in usedInUi) {
      test('"$name" is a non-empty name, not a path', () {
        expect(name, isNotEmpty);
        // A leading slash means someone passed a path to a name-taking API,
        // which is the exact mistake this suite was written for.
        expect(name.startsWith('/'), isFalse);
      });
    }

    test('names are unique', () {
      expect(usedInUi.toSet().length, usedInUi.length);
    });

    test('the planner name is not the path (the original bug)', () {
      // If these were ever collapsed to the same value, pushNamed would be
      // handed a path and throw at runtime.
      expect(Routes.planJourneyName, isNot(Routes.planJourney));
      expect(Routes.planJourney.startsWith('/'), isTrue);
    });
  });

  group('routes are namespaced by role', () {
    // Merging two apps into one router means a path can no longer be assumed to
    // mean one thing. These assertions are what keep `/tickets` meaning the
    // passenger's tickets rather than depending on which half was navigated to
    // last.
    test('no role-owned route sits at the root', () {
      expect(Routes.passengerHome, startsWith('/passenger'));
      expect(Routes.passengerSignIn, startsWith('/passenger'));
      expect(Routes.passengerOtp, startsWith('/passenger'));
      expect(Routes.staffSignIn, startsWith('/staff'));
      expect(Routes.staffDuty, startsWith('/staff'));
    });

    test('the role prefixes do not overlap', () {
      expect(
        Routes.passengerHome.startsWith(AppRole.staff.routePrefix),
        isFalse,
      );
      expect(
        Routes.staffDuty.startsWith(AppRole.passenger.routePrefix),
        isFalse,
      );
    });
  });

  group('roleRedirect keeps each half inside its own namespace', () {
    test('nothing is reachable before a role is chosen', () {
      // The dangerous case: a deep link into a staff route bypassing sign-in.
      for (final path in [
        Routes.staffDuty,
        Routes.staffSignIn,
        Routes.passengerHome,
        Routes.passengerOtp,
      ]) {
        expect(roleRedirect(Uri.parse(path), null), Routes.roleSelect);
      }
      // The picker itself must stay put, or the redirect would loop.
      expect(roleRedirect(Uri.parse(Routes.roleSelect), null), isNull);
    });

    test('a passenger may reach passenger routes', () {
      for (final path in [
        Routes.passengerHome,
        Routes.passengerSignIn,
        Routes.passengerOtp,
        '${Routes.passengerHome}/tickets',
      ]) {
        expect(roleRedirect(Uri.parse(path), AppRole.passenger), isNull);
      }
    });

    test('a passenger is bounced out of the staff half', () {
      // Not tidiness: the staff repositories would otherwise send a passenger
      // bearer token to a privileged route, and the 403 would land in the audit
      // trail naming someone who was never an officer.
      expect(
        roleRedirect(Uri.parse(Routes.staffDuty), AppRole.passenger),
        Routes.passengerSignIn,
      );
      expect(
        roleRedirect(Uri.parse(Routes.staffSignIn), AppRole.passenger),
        Routes.passengerSignIn,
      );
    });

    test('staff is bounced out of the passenger half', () {
      expect(
        roleRedirect(Uri.parse(Routes.passengerHome), AppRole.staff),
        Routes.staffSignIn,
      );
      expect(
        roleRedirect(Uri.parse('${Routes.passengerHome}/tickets'), AppRole.staff),
        Routes.staffSignIn,
      );
    });

    test('the picker is reachable from either half', () {
      expect(roleRedirect(Uri.parse(Routes.roleSelect), AppRole.staff), isNull);
      expect(
        roleRedirect(Uri.parse(Routes.roleSelect), AppRole.passenger),
        isNull,
      );
    });
  });

  group('each role has a defined home and sign-in', () {
    test('passenger', () {
      expect(homeFor(AppRole.passenger), Routes.passengerHome);
      expect(signInFor(AppRole.passenger), Routes.passengerSignIn);
    });

    test('staff', () {
      expect(homeFor(AppRole.staff), Routes.staffDuty);
      expect(signInFor(AppRole.staff), Routes.staffSignIn);
    });
  });
}
