import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/models/journey.dart';
import '../../journey_planner/domain/transport_repository.dart';
import 'location_service.dart';

/// Where a "use my location" request ended up.
///
/// A sealed union rather than a nullable field, so the compiler forces every
/// call site to decide what each state means instead of rendering a blank.
///
/// Equatable because these are values, not identities: without `==`, setting
/// the state to an identical `LocationDeclined` counts as a change and rebuilds
/// the field for no reason, and a test cannot assert "the state is this".
sealed class LocationLookup extends Equatable {
  const LocationLookup();

  /// True while a request is in flight.
  bool get isPending => this is LocationPending;

  @override
  List<Object?> get props => const [];
}

/// No request made yet; the field shows its normal prompt.
class LocationResting extends LocationLookup {
  const LocationResting();
}

/// A fix is being acquired, or the nearest stop is being looked up.
class LocationPending extends LocationLookup {
  const LocationPending();
}

/// A position was obtained and resolved to a named stop.
class LocationFound extends LocationLookup {
  const LocationFound({required this.stop, required this.point});

  final NearbyStop stop;
  final GeoPoint point;

  @override
  List<Object?> get props => [stop, point];
}

/// No position could be obtained — disabled, denied, or timed out.
///
/// [reason] decides the recovery the app can offer: re-requesting permission,
/// sending the passenger to system settings, or simply asking them to retry.
/// Collapsing these into one flag is what produces a dead-end error message.
class LocationDeclined extends LocationLookup {
  const LocationDeclined(this.reason);

  final LocationFailureReason reason;

  @override
  List<Object?> get props => [reason];
}

/// A fix arrived but no stop could be named: the position was too imprecise to
/// trust, or the network returned nothing nearby.
class LocationUnavailable extends LocationLookup {
  const LocationUnavailable(this.reason);

  final LocationFailureReason reason;

  @override
  List<Object?> get props => [reason];
}

/// Turns a raw position into a named stop the passenger can plan from.
///
/// Dependencies are read from [ref] inside [locate] rather than injected, which
/// is how a Riverpod Notifier reaches its collaborators — a top-level
/// NotifierProvider's create callback has no `ref` of its own to capture.
///
/// The whole flow — permission, fix, nearest stop — is exercised in tests
/// against two overridden providers, with no platform channel and no server.
class LocationLookupController extends Notifier<LocationLookup> {
  @override
  LocationLookup build() => const LocationResting();

  /// Acquires a fix and resolves it to the nearest stop.
  Future<void> locate() async {
    // Re-entry guard: a second tap while a fix is pending would otherwise raise
    // a duplicate permission prompt and race two lookups into one state field.
    if (state.isPending) return;

    state = const LocationPending();

    final result = await ref.read(locationServiceProvider).currentPosition();
    if (!result.isSuccess || result.point == null) {
      state = LocationDeclined(
        result.failure ?? LocationFailureReason.unknown,
      );
      return;
    }

    // A fix accurate only to a few hundred metres, in a city whose stops are
    // spaced a few hundred metres apart, would name the wrong stop with total
    // confidence. Refusing to guess is the correct behaviour, not a fallback.
    if (!result.isAccurateEnough) {
      state = const LocationUnavailable(LocationFailureReason.tooInaccurate);
      return;
    }

    state = await _nearestStop(result.point!);
  }

  /// The furthest a named stop may be from the passenger.
  ///
  /// Deliberately a second check, not a restatement of the server's radius. The
  /// endpoint already refuses anything beyond its own limit, so this is
  /// redundant when the app talks to the right server — and that is exactly why
  /// it is worth having. The API base URL is configurable and the app ships
  /// pointing at a demo build, so a wrong or stale server must not be able to
  /// name a stop 4,000 km away as "where you are". Failing closed is the only
  /// safe direction: a passenger who is told nothing can pick a stop by hand.
  ///
  /// Set at the edge of a long but possible walk so a legitimate far stop is
  /// still accepted.
  static const int maxPlausibleStopMeters = 2000;

  Future<LocationLookup> _nearestStop(GeoPoint point) async {
    try {
      final stops = await ref.read(transportRepositoryProvider).nearbyStops(point);
      if (stops.isEmpty) {
        // The server applies a radius, so an empty list means the position is
        // outside the area served rather than "the search failed".
        return const LocationUnavailable(
          LocationFailureReason.outsideServiceArea,
        );
      }

      final nearest = stops.first;
      // The server ranks by distance, so anything past the limit means we are
      // not talking to a server whose stop network covers this position.
      if (nearest.distanceMeters > maxPlausibleStopMeters) {
        return const LocationUnavailable(
          LocationFailureReason.outsideServiceArea,
        );
      }

      return LocationFound(stop: nearest, point: point);
    } on Object {
      // The position was fine; the stop lookup was not. Reporting "location
      // unavailable" would blame the GPS for a network problem.
      return const LocationUnavailable(LocationFailureReason.lookupFailed);
    }
  }

  /// Returns to the resting state so the field shows its prompt again.
  void reset() {
    state = const LocationResting();
  }
}
