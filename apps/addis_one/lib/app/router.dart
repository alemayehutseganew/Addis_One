import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/app_role.dart';
import '../core/models/journey_plan.dart';
import '../core/models/ticket.dart';
import '../core/models/vehicle.dart';
import '../features/auth/presentation/screens/role_select_screen.dart';
import '../features/passenger/auth/presentation/screens/otp_screen.dart';
import '../features/passenger/auth/presentation/screens/phone_entry_screen.dart';
import '../features/passenger/home/presentation/screens/home_screen.dart';
import '../features/passenger/journey_planner/presentation/screens/journey_search_screen.dart';
import '../features/passenger/journey_planner/presentation/screens/trips_screen.dart';
import '../features/passenger/profile/presentation/screens/profile_screen.dart';
import '../features/passenger/ticketing/presentation/screens/tickets_list_screen.dart';
import '../features/passenger/vehicle_code/presentation/screens/vehicle_code_screen.dart';
import '../features/passenger/vehicle_code/presentation/screens/vehicle_ticket_screen.dart';
import '../features/staff/auth/presentation/screens/sign_in_screen.dart';
import '../features/staff/duty/presentation/screens/duty_screen.dart';
import 'theme.dart';

/// Route table.
///
/// Named routes rather than inline `MaterialPageRoute` so deep links and
/// back-stack behaviour are declared in one place instead of scattered through
/// widget bodies.
///
/// ## The role namespace
///
/// Every route lives under `/passenger/--` or `/staff/--`, never at the root. The
/// two apps were separate binaries, so a path could only mean one thing; merging
/// them into one router would otherwise make `/tickets` mean the passenger's
/// tickets on one build and something else entirely on the next. Namespacing
/// keeps each path unambiguous, and [roleRedirect] enforces that a person
/// cannot reach the other half's screens by URL.
///
/// The distinction between [path] and [name] is not cosmetic: `pushNamed` looks
/// routes up by NAME and throws at runtime if no route carries that name. A
/// route declared with only a `path` compiles cleanly, passes the analyzer, and
/// fails on first tap -- which is exactly how a primary button ends up looking
/// enabled and doing nothing.
abstract final class Routes {
  /// The role picker. The app's only unscoped route.
  static const roleSelect = '/';

  static const passengerSignIn = '/passenger/sign-in';
  static const passengerOtp = '/passenger/otp';
  static const passengerHome = '/passenger/home';
  static const staffSignIn = '/staff/sign-in';
  static const staffDuty = '/staff/duty';

  // Passenger paths, relative to [passengerHome].
  static const planJourney = '/passenger/journey';
  static const tickets = '/passenger/tickets';
  static const vehicleCode = '/passenger/vehicle-code';
  static const vehicleTicket = '/passenger/vehicle-code/ticket';

  // Names, for named navigation.
  static const passengerSignInName = 'passenger-sign-in';
  static const passengerOtpName = 'passenger-otp';
  static const planJourneyName = 'plan-journey';
  static const ticketsName = 'tickets';
  static const tripsName = 'trips';
  static const profileName = 'profile';
  static const vehicleCodeName = 'vehicle-code';
  static const vehicleTicketName = 'vehicle-ticket';
}

/// Prefix every route of a given role shares.
extension RoleRoutePrefix on AppRole {
  String get routePrefix => switch (this) {
        AppRole.passenger => '/passenger',
        AppRole.staff => '/staff',
      };
}

/// Whether [uri] belongs to [role].
///
/// Used by [roleRedirect] to keep each half of the app inside its own namespace.
/// A `/staff/--` path reached while the passenger half is active is not merely
/// untidy -- the staff repositories would send a passenger bearer token to a
/// privileged route, and the resulting 403 in the audit trail would name a
/// passenger who was never an officer.
bool isRouteForRole(Uri uri, AppRole role) =>
    uri.path == '/' || uri.path.startsWith('${role.routePrefix}/');

/// Where a given role belongs when nothing else is known.
String homeFor(AppRole role) => switch (role) {
      AppRole.passenger => Routes.passengerHome,
      AppRole.staff => Routes.staffDuty,
    };

/// Where a given role signs in.
String signInFor(AppRole role) => switch (role) {
      AppRole.passenger => Routes.passengerSignIn,
      AppRole.staff => Routes.staffSignIn,
    };

/// Payload for the vehicle ticket route.
///
/// A named type rather than a bare `Map`, so a wrong-shaped navigation argument
/// is caught by the `is` check at the route instead of throwing on an untyped
/// map access.
class VehicleTicketArgs {
  const VehicleTicketArgs({
    required this.tickets,
    required this.vehicle,
    required this.quantityPaid,
  });

  /// One ticket per passenger in the group booking.
  final List<IssuedTicket> tickets;

  final VehicleProfile vehicle;

  /// Fares actually paid for, which may exceed [tickets].length if the backend
  /// issued partially. Carried so the screen can state the shortfall.
  final int quantityPaid;
}

GoRouter buildRouter({
  required ValueChanged<AppLocale> onLocaleSelected,
  required ValueChanged<AppRole> onRoleSelected,
  required VoidCallback onChangeRole,
  required AppRole? Function() roleReader,
  required ValueListenable<AppRole?> roleListenable,
  AppRole? initialRole,
}) {
  return GoRouter(
    // Resuming straight into a role means someone who always signs in as staff
    // is not asked to pick again on every launch. Null, meaning no memory of a
    // role, sends them to the picker, which is the safe default.
    initialLocation: initialRole == null
        ? Routes.roleSelect
        : homeFor(initialRole),
    // Re-runs [roleRedirect] whenever the role changes, not only on navigation.
    refreshListenable: roleListenable,
    redirect: (context, state) => roleRedirect(state.uri, roleReader()),
    routes: [
      GoRoute(
        path: Routes.roleSelect,
        name: Routes.roleSelect,
        builder: (context, state) => RoleSelectScreen(
          onRoleSelected: onRoleSelected,
          onChangeRole: onChangeRole,
        ),
      ),

      // -- Passenger role --

      GoRoute(
        path: Routes.passengerHome,
        name: Routes.passengerHome,
        builder: (context, state) =>
            HomeScreen(onLocaleSelected: onLocaleSelected),
        routes: [
          GoRoute(
            path: 'journey',
            name: Routes.planJourneyName,
            builder: (context, state) {
              // The home screen passes a resolved origin through `extra` when the
              // passenger used their current location. Read defensively: a
              // `Map<String, dynamic>` cast against the wrong shape throws, and a
              // navigation argument must never be able to crash the planner.
              final extra = state.extra;
              Place? origin;
              if (extra is Map && extra['origin'] is Place) {
                origin = extra['origin'] as Place;
              }
              return JourneySearchScreen(initialOrigin: origin);
            },
          ),
          GoRoute(
            path: 'tickets',
            name: Routes.ticketsName,
            builder: (context, state) => const TicketsListScreen(),
          ),
          GoRoute(
            path: 'trips',
            name: Routes.tripsName,
            builder: (context, state) => const TripsScreen(),
          ),
          GoRoute(
            path: 'profile',
            name: Routes.profileName,
            builder: (context, state) => ProfileScreen(
              onLocaleSelected: onLocaleSelected,
            ),
          ),
          GoRoute(
            path: 'vehicle-code',
            name: Routes.vehicleCodeName,
            builder: (context, state) => const VehicleCodeScreen(),
            routes: [
              GoRoute(
                path: 'ticket',
                name: Routes.vehicleTicketName,
                // Carries the issued ticket and its vehicle through `extra`, which
                // is how the final steps are reached without the screen having to
                // re-fetch or re-derive anything. Read defensively: a navigation
                // argument must never be able to crash the ticket screen.
                builder: (context, state) {
                  final extra = state.extra;
                  if (extra is! VehicleTicketArgs) {
                    return Scaffold(
                      appBar: AppBar(title: const Text('Addis One')),
                      body: const Center(child: Text('No ticket to show')),
                    );
                  }
                  return VehicleTicketScreen(
                    tickets: extra.tickets,
                    vehicle: extra.vehicle,
                    quantityPaid: extra.quantityPaid,
                  );
                },
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.passengerSignIn,
        name: Routes.passengerSignInName,
        builder: (context, state) => const PhoneEntryScreen(),
      ),
      GoRoute(
        path: Routes.passengerOtp,
        name: Routes.passengerOtpName,
        builder: (context, state) => const OtpScreen(),
      ),

      // -- Staff role --

      // Only the two entry points are routes. Everything below the duty screen
      // pushes imperatively, exactly as it did in the standalone staff app: those
      // screens are opened from a capability-driven menu the server builds at
      // runtime, so there is no fixed set of paths to declare, and inventing
      // them would mean a route table to edit every time a role gains a duty.
      GoRoute(
        path: Routes.staffSignIn,
        name: Routes.staffSignIn,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: Routes.staffDuty,
        name: Routes.staffDuty,
        builder: (context, state) => const StaffDutyScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Addis One')),
      body: Center(child: Text('Route not found: ${state.uri}')),
    ),
  );
}

/// Sends anyone whose path belongs to the other role back to their own.
///
/// Returns null to let navigation proceed, which is what a GoRouter redirect
/// means. Exported and pure so the rule can be tested without a widget tree -- /// this is the one piece of the router that enforces a security-relevant
/// boundary, and it should not need a pumpTest to be trusted.
String? roleRedirect(Uri uri, AppRole? selectedRole) {
  // No role yet: everything except the picker is premature. Landing here is how
  // a deep link into a staff route would otherwise bypass the sign-in screen
  // entirely.
  if (selectedRole == null) {
    return uri.path == Routes.roleSelect ? null : Routes.roleSelect;
  }
  if (isRouteForRole(uri, selectedRole)) return null;
  return signInFor(selectedRole);
}

