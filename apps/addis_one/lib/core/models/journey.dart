import 'package:equatable/equatable.dart';

import '../money.dart';

/// Transport modes. Mirrors the backend `TransportMode` enum.
enum TransportMode {
  bus('BUS'),
  taxi('TAXI'),
  train('TRAIN'),
  walk('WALK');

  const TransportMode(this.wire);
  final String wire;

  static TransportMode fromWire(String value) {
    return TransportMode.values.firstWhere(
      (m) => m.wire == value,
      orElse: () => TransportMode.bus,
    );
  }
}

/// Data freshness, mirroring the backend enum.
///
/// This exists so the UI never presents stale information as live. A bus "due in
/// 2 minutes" computed from a GPS fix that is 15 minutes old is worse than no
/// information at all.
enum DataFreshness {
  realTime('REAL_TIME'),
  estimated('ESTIMATED'),
  scheduled('SCHEDULED'),
  stale('STALE'),
  unknown('UNKNOWN');

  const DataFreshness(this.wire);
  final String wire;

  bool get isLive => this == DataFreshness.realTime;
  bool get isUnreliable =>
      this == DataFreshness.stale || this == DataFreshness.unknown;

  static DataFreshness fromWire(String value) {
    return DataFreshness.values.firstWhere(
      (f) => f.wire == value,
      orElse: () => DataFreshness.unknown,
    );
  }
}

/// A geographic point.
class GeoPoint extends Equatable {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  @override
  List<Object?> get props => [latitude, longitude];
}

/// One segment of a planned journey.
class JourneyLeg extends Equatable {
  const JourneyLeg({
    required this.sequence,
    required this.mode,
    required this.durationSeconds,
    this.fromLabel,
    this.toLabel,
    this.routeName,
    this.departureTime,
    this.arrivalTime,
    this.distanceMeters = 0,
    this.fare = Money.zero,
  });

  final int sequence;
  final TransportMode mode;
  final int durationSeconds;
  final String? fromLabel;
  final String? toLabel;
  final String? routeName;
  final DateTime? departureTime;
  final DateTime? arrivalTime;
  final int distanceMeters;
  final Money fare;

  bool get isWalk => mode == TransportMode.walk;

  /// "42 min" / "1 h 05"
  String get durationLabel {
    if (durationSeconds < 60) return '$durationSeconds sec';
    final minutes = (durationSeconds / 60).round();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return rem == 0 ? '$hours h' : '$hours h ${rem.toString().padLeft(2, '0')}';
  }

  @override
  List<Object?> get props => [
        sequence,
        mode,
        durationSeconds,
        fromLabel,
        toLabel,
        routeName,
        departureTime,
        arrivalTime,
        distanceMeters,
        fare,
      ];
}

/// A complete planned itinerary returned by the journey engine.
///
/// Fare is server-computed. The client never recalculates a fare — that would
/// risk client/server divergence, which is how passengers get charged amounts
/// the backend cannot explain.
class PlannedJourney extends Equatable {
  const PlannedJourney({
    required this.id,
    required this.legs,
    required this.totalFare,
    required this.totalDurationSeconds,
    required this.walkingMeters,
    required this.transferCount,
    this.departureTime,
    this.journeyId,
    this.transferDiscountFils = 0,
    this.freshness = DataFreshness.unknown,
  });

  final String id;
  final List<JourneyLeg> legs;
  final Money totalFare;
  final int totalDurationSeconds;
  final int walkingMeters;
  final int transferCount;
  final DateTime? departureTime;

  /// Server-side id of the stored fare quote, or null when this option was not
  /// persisted (i.e. the passenger declined the best-ranked quote).
  ///
  /// Purchase requires it: the server re-reads the FareCalculation attached to
  /// this journey to verify the amount charged, so an option without one cannot
  /// be bought and must be re-planned.
  final String? journeyId;

  /// Fils waived by the transfer rule. Zero on a direct journey.
  ///
  /// Shown separately from the total so the passenger can see the concession
  /// rather than having it silently folded into a lower number.
  final int transferDiscountFils;

  /// How current this information is. Never claim live data that is not.
  final DataFreshness freshness;

  /// True when this option can be bought as-is.
  bool get isPurchasable => journeyId != null && journeyId!.isNotEmpty;

  /// The fare this option would have cost without the transfer discount.
  Money get undiscountedFare =>
      Money(totalFare.fils + transferDiscountFils);

  int get boardingLegs => legs.where((l) => !l.isWalk).length;

  String get durationLabel {
    final minutes = (totalDurationSeconds / 60).round();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return rem == 0 ? '$hours h' : '$hours h ${rem.toString().padLeft(2, '0')}';
  }

  @override
  List<Object?> get props => [
        id,
        legs,
        totalFare,
        totalDurationSeconds,
        walkingMeters,
        transferCount,
        departureTime,
        journeyId,
        transferDiscountFils,
        freshness,
      ];
}
