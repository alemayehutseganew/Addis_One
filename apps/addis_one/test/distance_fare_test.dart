import 'package:addis_one/core/models/journey.dart';
import 'package:addis_one/features/passenger/vehicle_code/data/demo_vehicle_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Distance-based boarding fares.
///
/// The rule under test: the client never prices anything. It sends coordinates
/// and renders whatever comes back. These assert that a position changes the
/// *quote*, and — just as important — that refusing to share a location still
/// yields a usable flat fare rather than a dead end at the bus door.
void main() {
  final repo = DemoVehicleRepository();

  /// Piazza, one of the seeded route-7 stops.
  const atPiazza = GeoPoint(latitude: 9.0192, longitude: 38.7525);

  /// Roughly 500 m south-west of Piazza — still on the route.
  const nearPiazza = GeoPoint(latitude: 9.0145, longitude: 38.7475);

  /// Kilimanjaro. Nowhere near any seeded route.
  const farAway = GeoPoint(latitude: -3.0674, longitude: 37.3556);

  group('Distance fare', () {
    test('a position produces a quote naming the stop it priced from',
        () async {
      final vehicle =
          await repo.lookupVehicle('AA 12345', boardingPoint: nearPiazza);

      expect(vehicle, isNotNull);
      expect(vehicle!.isDistanceBased, isTrue);
      expect(vehicle.boardingStopLabel, isNotNull);
      expect(vehicle.boardingDistanceMeters, isNotNull);
    });

    test('the fare is never below the flat base fare', () async {
      final flat = await repo.lookupVehicle('AA 12345');
      final quoted =
          await repo.lookupVehicle('AA 12345', boardingPoint: atPiazza);

      // Standing exactly on a stop is the cheapest possible boarding and must
      // never undercut the published price.
      expect(quoted!.fare.fils, greaterThanOrEqualTo(flat!.fare.fils));
    });

    test('standing further from the stop cannot cost less', () async {
      final near =
          await repo.lookupVehicle('AA 12345', boardingPoint: nearPiazza);
      final onStop =
          await repo.lookupVehicle('AA 12345', boardingPoint: atPiazza);

      expect(near!.fare.fils, greaterThanOrEqualTo(onStop!.fare.fils));
    });

    test('a position outside the served area falls back to the flat fare',
        () async {
      final flat = await repo.lookupVehicle('AA 12345');
      final quoted =
          await repo.lookupVehicle('AA 12345', boardingPoint: farAway);

      // Snapping a passenger in Kilimanjaro to "Piazza" would produce a
      // confidently wrong price, so no distance quote is issued at all.
      expect(quoted!.fare, flat!.fare);
      expect(quoted.isDistanceBased, isFalse);
    });

    test('no position still yields the flat fare and a purchasable vehicle',
        () async {
      final vehicle = await repo.lookupVehicle('AA 12345');

      expect(vehicle!.isDistanceBased, isFalse);
      expect(
        vehicle.isPurchasable,
        isTrue,
        reason: 'permission denied must not break the purchase flow',
      );
    });

    test('an unknown code is still null, with or without a position', () async {
      expect(await repo.lookupVehicle('AA 00000'), isNull);
      expect(
        await repo.lookupVehicle('AA 00000', boardingPoint: atPiazza),
        isNull,
      );
    });
  });

  group('Fare explanation', () {
    test('a distance quote explains itself; a flat one says so', () async {
      final quoted =
          await repo.lookupVehicle('AA 12345', boardingPoint: nearPiazza);
      final flat = await repo.lookupVehicle('AA 12345');

      expect(quoted!.fareBasisFor(false), contains('Distance fare'));
      expect(flat!.fareBasisFor(false), 'Flat fare');
    });

    test('the explanation is localised and never empty', () async {
      final quoted =
          await repo.lookupVehicle('AA 12345', boardingPoint: nearPiazza);

      expect(quoted!.fareBasisFor(true), isNotEmpty);
      expect(quoted.fareBasisFor(true), isNot(quoted.fareBasisFor(false)));
    });
  });
}