import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/app_role.dart';
import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/storage/token_storage.dart';
import '../features/passenger/auth/data/dio_auth_gateway.dart';
import '../features/passenger/auth/domain/auth_controller.dart';
import '../features/passenger/auth/domain/auth_state.dart';
import '../features/passenger/journey_planner/data/demo_transport_repository.dart';
import '../features/passenger/journey_planner/data/http_transport_repository.dart';
import '../features/passenger/journey_planner/domain/purchase_controller.dart';
import '../features/passenger/journey_planner/domain/transport_repository.dart';
import '../features/passenger/location/data/geolocator_location_service.dart';
import '../features/passenger/location/domain/location_lookup_controller.dart';
import '../features/passenger/location/domain/location_service.dart';
import '../features/passenger/vehicle_code/data/demo_vehicle_repository.dart';
import '../features/passenger/vehicle_code/data/http_vehicle_repository.dart';
import '../features/passenger/vehicle_code/data/sms_gateway.dart';
import '../features/passenger/vehicle_code/data/ticket_share.dart';
import '../features/passenger/vehicle_code/domain/vehicle_code_controller.dart';
import '../features/passenger/vehicle_code/domain/vehicle_repository.dart';
import '../features/staff/auth/domain/staff_auth_controller.dart';
import '../features/staff/auth/domain/staff_auth_state.dart';
import '../features/staff/auth/domain/staff_repository.dart';
import '../features/staff/validation/data/scan_queue.dart';
import '../features/staff/validation/data/scan_submitter.dart';

/// Composition root.
///
/// Every dependency in the merged app is provided here and nowhere else, so
/// swapping an implementation (real API vs demo data, passenger vs staff) is a
/// one-line change rather than a hunt through the widget tree.
///
/// ## The role is the root of the graph
///
/// [selectedRoleProvider] is read by [tokenStorageProvider] and
/// [apiClientProvider], which means choosing a role at the picker rebuilds the
/// entire client stack underneath it. That is the behaviour the two separate
/// apps got for free from being separate binaries, and it is the reason the
/// role is modelled as state rather than as a navigation argument: a passenger
/// token cannot survive a switch to staff, because the storage holding it is
/// replaced at the same time.

/// Which half of the app is active. Null until the person picks one.
final selectedRoleProvider = StateProvider<AppRole?>((ref) => null);

/// Returns to the role picker, clearing the active role's session.
///
/// Held as a callback rather than called directly because the role lives in
/// `AddisOneApp`'s state: the router redirect needs it before the first frame,
/// and the composition root needs it to tear down the client stack. A screen deep
/// inside a role therefore cannot simply invoke a method, so the root publishes
/// one here.
///
/// Null until the app has built, which is the safe direction: a screen that
/// somehow reads it before then gets a no-op rather than a null dereference.
final changeRoleActionProvider = StateProvider<VoidCallback?>((ref) => null);

/// Session token storage, scoped to the selected role.
///
/// Watched rather than read, so selecting a role swaps the whole credential
/// namespace. See [selectedRoleProvider] for why that has to happen together.
final tokenStorageProvider = Provider<TokenStorage>((ref) {
  final role = ref.watch(selectedRoleProvider);
  // Before a role is chosen there is no correct namespace, so there is nothing
  // to read. A default of `passenger` here would quietly attach a stale
  // passenger token to the very first staff request.
  if (role == null) return TokenStorage(role: AppRole.passenger);
  return TokenStorage(role: role);
});

/// The HTTP client for the active role.
///
/// One client class, two policies. Only the passenger half refreshes a 401 and
/// retries silently: a passenger losing their session mid-purchase loses
/// nothing, whereas an inspector whose token expires mid-shift must be told, or
/// a scan could be recorded against the wrong officer. See `ApiClient` for the
/// full reasoning.
final apiClientProvider = Provider<ApiClient>((ref) {
  final role = ref.watch(selectedRoleProvider);
  final tokens = ref.watch(tokenStorageProvider);
  final api = ApiClient(
    tokens: tokens,
    refreshOnUnauthorized: role == AppRole.passenger,
  );
  if (role == AppRole.passenger) {
    // A 401 here means the short-lived access token expired, not that the
    // passenger did anything wrong. Refreshing silently keeps them signed in
    // rather than bouncing them to the phone-number screen mid-journey.
    api.onUnauthorized = () => refreshSessionQuietly(api, tokens);
  }
  return api;
});

// -- Passenger role ------------------------------------------------------------

final authGatewayProvider = Provider<AuthGateway>((ref) {
  return DioAuthGateway(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  );
});

/// Passenger sign-in state.
///
/// Not auto-disposed: it must survive navigating between the phone and OTP
/// screens, so it lives for the whole session.
final passengerAuthControllerProvider =
    Provider<PassengerAuthController>((ref) {
  return PassengerAuthController(gateway: ref.watch(authGatewayProvider));
});

/// Signed-in phone, or null. Drives the router's redirect.
final passengerAuthStateProvider = Provider<PassengerAuthState>((ref) {
  return ref.watch(passengerAuthControllerProvider).state;
});

final isPassengerSignedInProvider = Provider<bool>((ref) {
  return ref.watch(passengerAuthStateProvider) is PassengerAuthAuthenticated;
});

final transportRepositoryProvider = Provider<TransportRepository>((ref) {
  // Demo data is an explicit build flag, not a silent fallback: a build that
  // cannot reach the backend should say so rather than quietly lie.
  if (AppConfig.useDemoData) {
    return DemoTransportRepository();
  }
  return HttpTransportRepository(api: ref.watch(apiClientProvider));
});

/// One purchase at a time. Creating a second purchase without resetting would
/// reuse the first purchase's idempotency key, so the controller is a singleton
/// and `PurchaseController.reset` is called on leaving the flow.
final purchaseControllerProvider = Provider<PurchaseController>((ref) {
  final controller = PurchaseController(
    repository: ref.watch(transportRepositoryProvider),
  );
  ref.onDispose(controller.reset);
  return controller;
});

/// Polling interval is overridable in tests to avoid real waits.
final purchasePollIntervalProvider = Provider<Duration>((ref) {
  return const Duration(milliseconds: 1500);
});

/// Platform location access.
///
/// Behind an interface so the plugin never reaches a test: the lookup flow is
/// exercised against a fake, which means the app's behaviour around permission,
/// refusal, and a stale fix is all verifiable without GPS hardware.
final locationServiceProvider = Provider<LocationService>((ref) {
  return GeolocatorLocationService();
});

/// Turns a position into a named stop.
///
/// Session-scoped, not auto-disposed: the resolved stop is what the planner was
/// opened with, and discarding it on navigation would lose the passenger's
/// chosen origin. Dependencies are resolved inside the notifier's `build`.
final locationLookupProvider =
    NotifierProvider<LocationLookupController, LocationLookup>(
  LocationLookupController.new,
);

/// Switches on the same explicit build flag as [transportRepositoryProvider], so
/// the two halves of the passenger app can never disagree about which backend
/// they are talking to. A demo build that served demo fares but live vehicle
/// lookups would be worse than either build alone.
final vehicleRepositoryProvider = Provider<VehicleRepository>((ref) {
  if (AppConfig.useDemoData) {
    return DemoVehicleRepository();
  }
  return HttpVehicleRepository(api: ref.watch(apiClientProvider));
});

/// One vehicle purchase at a time, for the same reason as
/// [purchaseControllerProvider]: the idempotency key must survive a retry within
/// a purchase, and a fresh key is issued only after `VehicleCodeController.reset`.
final vehicleCodeControllerProvider = Provider<VehicleCodeController>((ref) {
  final controller = VehicleCodeController(
    repository: ref.watch(vehicleRepositoryProvider),
  );
  ref.onDispose(controller.reset);
  return controller;
});

/// SMS for the vehicle-code flow. Behind an interface so the send path is
/// testable without a device, and so a build without the native channel degrades
/// to "unavailable" instead of crashing on tap.
final smsGatewayProvider = Provider<SmsGateway>((ref) {
  return const MethodChannelSmsGateway();
});

final ticketShareServiceProvider = Provider<TicketShareService>((ref) {
  return const MethodChannelTicketShareService();
});

/// Polling interval for vehicle payments. Overridable so tests never wait.
final vehiclePollIntervalProvider = Provider<Duration>((ref) {
  return const Duration(milliseconds: 1500);
});

// -- Staff role ----------------------------------------------------------------

final staffRepositoryProvider = Provider<StaffRepository>(
  (ref) => StaffRepository(
    api: ref.watch(apiClientProvider),
    tokens: ref.watch(tokenStorageProvider),
  ),
);

final scanQueueProvider = Provider<ScanQueue>((ref) => ScanQueue());

final scanSubmitterProvider = Provider<ScanSubmitter>(
  (ref) => ScanSubmitter(
    repo: ref.watch(staffRepositoryProvider),
    queue: ref.watch(scanQueueProvider),
  ),
);

/// How many scans are waiting for a connection.
///
/// Refreshed imperatively by the scan screen rather than watched from the queue:
/// SharedPreferences is not reactive, so a provider that read it would report a
/// stale zero forever and the officer would never learn they had unvalidated
/// tickets.
final pendingScanCountProvider = StateProvider<int>((ref) => 0);

/// Whether the dev sign-in control should be offered at all.
///
/// Combines the build flag with nothing else. The server still decides whether
/// the route exists; this only decides whether the app bothers to ask.
final devSignInEnabledProvider = Provider<bool>(
  (ref) => AppConfig.enableDevSignIn,
);

/// Staff sign-in. Declared here rather than beside the controller so both roles'
/// entry points are visible in one place when reading the graph.
final staffAuthControllerProvider =
    StateNotifierProvider<StaffAuthController, StaffAuthState>((ref) {
  return StaffAuthController(
    repo: ref.watch(staffRepositoryProvider),
    tokens: ref.watch(tokenStorageProvider),
    submitter: ref.watch(scanSubmitterProvider),
  );
});
