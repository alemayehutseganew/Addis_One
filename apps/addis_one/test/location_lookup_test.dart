import 'package:addis_one/app/providers.dart';
import 'package:addis_one/core/models/journey.dart';
import 'package:addis_one/core/models/journey_plan.dart';
import 'package:addis_one/features/passenger/journey_planner/domain/transport_repository.dart';
import 'package:addis_one/features/passenger/location/domain/location_lookup_controller.dart';
import 'package:addis_one/features/passenger/location/domain/location_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A location service that returns whatever the test hands it.
class FakeLocationService implements LocationService {
  FakeLocationService(this.result);

  LocationResult result;
  int calls = 0;

  @override
  Future<LocationResult> currentPosition() async {
    calls++;
    return result;
  }
}

/// Transport fake that only cares about [nearbyStops]; the rest of the contract
/// is irrelevant to this flow and throws rather than pretending to work.
class FakeTransport implements TransportRepository {
  FakeTransport({this.nearby = const []});

  final List<NearbyStop> nearby;
  int nearbyCalls = 0;

  @override
  Future<List<NearbyStop>> nearbyStops(GeoPoint point) async {
    nearbyCalls++;
    return nearby;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used by this test');
}

/// Transport fake whose stop lookup fails.
class ThrowingTransport implements TransportRepository {
  @override
  Future<List<NearbyStop>> nearbyStops(GeoPoint point) async =>
      throw StateError('network down');

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used by this test');
}

/// The origin field's whole decision, with no GPS and no server.
void main() {
  final somewhere = const GeoPoint(latitude: 9.02, longitude: 38.75);

  Place placeNamed(String name) => Place(
        id: 'id-$name',
        code: name.toUpperCase(),
        name: name,
        latitude: 9.02,
        longitude: 38.75,
      );

  NearbyStop near(String name, int metres) =>
      NearbyStop(place: placeNamed(name), distanceMeters: metres);

  ProviderContainer containerWith(
    LocationService service,
    TransportRepository transport,
  ) {
    final container = ProviderContainer(
      overrides: [
        // The controller reads both of these through ref.read, so overriding
        // the providers is enough — no plugin and no network are reached.
        locationServiceProvider.overrideWithValue(service),
        transportRepositoryProvider.overrideWithValue(transport),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }
group('LocationLookupController', () {
    test('starts at rest, not pending', () {
      final container = containerWith(
        FakeLocationService(
          const LocationResult.success(GeoPoint(latitude: 9, longitude: 38)),
        ),
        FakeTransport(),
      );
      expect(container.read(locationLookupProvider), isA<LocationResting>());
    });

    test('resolves a good fix to the nearest stop', () async {
      final container = containerWith(
        FakeLocationService(
          LocationResult.success(somewhere, accuracyMeters: 8),
        ),
        FakeTransport(nearby: [near('Arat Kilo', 40)]),
      );

      await container.read(locationLookupProvider.notifier).locate();

      final state = container.read(locationLookupProvider) as LocationFound;
      expect(state.stop.place.name, 'Arat Kilo');
      expect(state.stop.distanceMeters, 40);
    });

    test('reports a declined permission instead of crashing', () async {
      final container = containerWith(
        FakeLocationService(
          const LocationResult.failed(
            LocationFailureReason.permissionDenied,
          ),
        ),
        FakeTransport(),
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(
        container.read(locationLookupProvider),
        const LocationDeclined(LocationFailureReason.permissionDenied),
      );
    });

    test('keeps denied and denied-forever distinguishable', () async {
      // The recoveries differ: one can be re-requested, the other needs a trip
      // to system settings. Collapsing them is what produces a dead end.
      final again = containerWith(
        FakeLocationService(
          const LocationResult.failed(LocationFailureReason.permissionDenied),
        ),
        FakeTransport(),
      );
      await again.read(locationLookupProvider.notifier).locate();

      final forever = containerWith(
        FakeLocationService(
          const LocationResult.failed(
            LocationFailureReason.permissionDeniedForever,
          ),
        ),
        FakeTransport(),
      );
      await forever.read(locationLookupProvider.notifier).locate();

      final a = again.read(locationLookupProvider) as LocationDeclined;
      final b = forever.read(locationLookupProvider) as LocationDeclined;
      expect(a.reason, isNot(b.reason));
    });

    test('refuses a fix too imprecise to name a stop', () async {
      // Addis stops sit a few hundred metres apart. A 900 m fix would pick a
      // neighbouring stop and present it with total confidence.
      final container = containerWith(
        FakeLocationService(
          LocationResult.success(somewhere, accuracyMeters: 900),
        ),
        FakeTransport(nearby: [near('Arat Kilo', 10)]),
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(
        container.read(locationLookupProvider),
        const LocationUnavailable(LocationFailureReason.tooInaccurate),
      );
    });

    test('never asks the server for a stop it cannot place', () async {
      // Ordering matters: a refused permission must not produce a stop lookup,
      // which would be a request carrying no meaningful coordinate.
      final transport = FakeTransport(nearby: [near('Arat Kilo', 5)]);
      final container = containerWith(
        FakeLocationService(
          const LocationResult.failed(LocationFailureReason.serviceDisabled),
        ),
        transport,
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(transport.nearbyCalls, 0);
    });

    test('blames the network, not the GPS, when the stop lookup fails',
        () async {
      final container = containerWith(
        FakeLocationService(
          LocationResult.success(somewhere, accuracyMeters: 5),
        ),
        ThrowingTransport(),
      );

      await container.read(locationLookupProvider.notifier).locate();

      // A valid fix plus a failed lookup must not read as "location
      // unavailable", which would send the passenger to check their GPS.
      expect(container.read(locationLookupProvider), isA<LocationUnavailable>());
    });

    test('handles a position with no stops returned', () async {
      final container = containerWith(
        FakeLocationService(
          LocationResult.success(somewhere, accuracyMeters: 5),
        ),
        FakeTransport(),
      );

      await container.read(locationLookupProvider.notifier).locate();

      // An empty list means the server's radius found nothing, so the passenger
      // is outside the served area. Reporting "no fix" would blame a GPS that
      // returned a perfect position.
      expect(
        container.read(locationLookupProvider),
        const LocationUnavailable(
          LocationFailureReason.outsideServiceArea,
        ),
      );
    });

    test('never blames the GPS when the stop lookup fails', () async {
      // The fix was good; the request failed. The passenger must not be sent to
      // check location settings, which were already correct.
      final container = containerWith(
        FakeLocationService(
          LocationResult.success(somewhere, accuracyMeters: 5),
        ),
        ThrowingTransport(),
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(
        container.read(locationLookupProvider),
        const LocationUnavailable(LocationFailureReason.lookupFailed),
      );
    });

    test('refuses a stop that is implausibly far away', () async {
      // Regression: a fix in Delhi was served "Bole, 4,253,742 m" and the app
      // displayed that as the passenger's origin. The server now filters by
      // radius, but the client re-checks rather than trusting the response: a
      // misconfigured or wrong server must not be able to place someone at a
      // stop on another continent.
      final container = containerWith(
        FakeLocationService(
          const LocationResult.success(
            GeoPoint(latitude: 12.9716, longitude: 77.5946),
            accuracyMeters: 5,
          ),
        ),
        FakeTransport(nearby: [near('Arat Kilo', 4253742)]),
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(
        container.read(locationLookupProvider),
        const LocationUnavailable(
          LocationFailureReason.outsideServiceArea,
        ),
      );
    });

    test('still accepts a stop at the edge of walking distance', () async {
      // The guard must not reject a legitimately distant stop: 1.8 km is a long
      // but possible walk, and the passenger is the one who knows.
      final container = containerWith(
        FakeLocationService(
          const LocationResult.success(
            GeoPoint(latitude: 12.9716, longitude: 77.5946),
            accuracyMeters: 5,
          ),
        ),
        FakeTransport(nearby: [near('Arat Kilo', 1800)]),
      );

      await container.read(locationLookupProvider.notifier).locate();

      expect(container.read(locationLookupProvider), isA<LocationFound>());
    });

    test('ignores a second tap while a lookup is already running', () async {
      // Two taps must not raise two permission prompts or race two lookups
      // into one state field.
      final service = FakeLocationService(
        LocationResult.success(somewhere, accuracyMeters: 5),
      );
      final container = containerWith(
        service,
        FakeTransport(nearby: [near('Arat Kilo', 20)]),
      );

      final notifier = container.read(locationLookupProvider.notifier);
      await Future.wait<void>([notifier.locate(), notifier.locate()]);

      expect(service.calls, 1);
    });
  });

  group('NearbyStop.displayDistance', () {
    const blank = Place(id: 'a', code: 'A', name: 'A');

    test('uses metres under a kilometre', () {
      expect(
        const NearbyStop(place: blank, distanceMeters: 40).displayDistance,
        '40 m',
      );
    });

    test('switches to kilometres with one decimal', () {
      expect(
        const NearbyStop(place: blank, distanceMeters: 1400).displayDistance,
        '1.4 km',
      );
    });
  });
}