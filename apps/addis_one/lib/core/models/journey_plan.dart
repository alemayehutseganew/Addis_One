import 'package:equatable/equatable.dart';

import '../money.dart';
import 'journey.dart';

/// A stop or station returned by the search endpoint.
class Place extends Equatable {
  const Place({
    required this.id,
    required this.code,
    required this.name,
    this.nameAm,
    this.latitude,
    this.longitude,
    this.zone,
    this.kind = PlaceKind.stop,
  });

  final String id;
  final String code;
  final String name;
  final String? nameAm;
  final double? latitude;
  final double? longitude;
  final String? zone;
  final PlaceKind kind;

  /// Best available display name for the active locale.
  String displayName({required bool isAmharic}) =>
      (isAmharic && nameAm != null && nameAm!.isNotEmpty) ? nameAm! : name;

  @override
  List<Object?> get props =>
      [id, code, name, nameAm, latitude, longitude, zone, kind];
}

enum PlaceKind {
  stop,
  station,
  unknown;

  static PlaceKind fromWire(String? value) {
    switch (value) {
      case 'stop':
        return PlaceKind.stop;
      case 'station':
        return PlaceKind.station;
      default:
        return PlaceKind.unknown;
    }
  }

  static PlaceKind fromJson(Map<String, dynamic> json) =>
      fromWire(json['kind'] as String?);
}

/// Request body for `POST /api/v1/journeys/plan`.
///
/// The wire shape is three flat keys — `originStopId`, `destinationStopId`,
/// `departureTime` — because that is all the backend DTO accepts. An earlier
/// version of this class sent nested `origin`/`destination` objects plus a
/// `preferences` block. That was never accepted: `forbidNonWhitelisted` is on
/// in main.ts, so the surplus keys were themselves the reason every search came
/// back 400, and no journey could be planned or purchased from the handset.
///
/// The preference fields below are therefore *not* sent. The planner has no
/// server-side concept of a walk limit, transfer count, accessibility, or mode
/// filter — its DTO takes only the two stop ids and an optional departure time.
/// They are kept as client-side documentation of the intent, and must not be
/// added to [toJson] until the backend DTO grows the matching fields. Adding
/// them again would reintroduce the 400.
class JourneyPlanRequest extends Equatable {
  const JourneyPlanRequest({
    required this.origin,
    required this.destination,
    required this.departureTime,
    this.maxWalkingMeters = 1000,
    this.preferFewestTransfers = false,
    this.accessibleOnly = false,
    this.modes = const {
      TransportMode.bus,
      TransportMode.train,
      TransportMode.taxi,
    },
  });

  final Place origin;
  final Place destination;
  final DateTime departureTime;
  final int maxWalkingMeters;
  final bool preferFewestTransfers;
  final bool accessibleOnly;
  final Set<TransportMode> modes;

  /// The server identifies a stop by its UUID alone. The latitude/longitude the
  /// client also holds are for display only — sending them invites the DTO to
  /// grow optional sub-objects that silently never get used.
  Map<String, dynamic> toJson() => {
        'originStopId': origin.id,
        'destinationStopId': destination.id,
        'departureTime': departureTime.toUtc().toIso8601String(),
      };

  @override
  List<Object?> get props => [
        origin,
        destination,
        departureTime,
        maxWalkingMeters,
        preferFewestTransfers,
        accessibleOnly,
        modes,
      ];
}

/// The planner response.
///
/// **Fare is server-computed and never recomputed on the device.** The client
/// displays whatever the backend returned. Recalculating here would let the two
/// disagree, producing a quote the backend cannot honour or explain.
class JourneyPlan extends Equatable {
  const JourneyPlan({
    required this.journeys,
    this.originLabel,
    this.destinationLabel,
  });

  final List<PlannedJourney> journeys;
  final String? originLabel;
  final String? destinationLabel;

  bool get isEmpty => journeys.isEmpty;

  /// Cheapest option, or null when there are none.
  PlannedJourney? get cheapest {
    if (journeys.isEmpty) return null;
    final sorted = [...journeys]
      ..sort((a, b) => a.totalFare.fils.compareTo(b.totalFare.fils));
    return sorted.first;
  }

  /// Fastest option, or null when there are none.
  PlannedJourney? get fastest {
    if (journeys.isEmpty) return null;
    final sorted = [...journeys]
      ..sort((a, b) =>
          a.totalDurationSeconds.compareTo(b.totalDurationSeconds));
    return sorted.first;
  }

  /// Fewest transfers, tie-broken by duration.
  PlannedJourney? get simplest {
    if (journeys.isEmpty) return null;
    final sorted = [...journeys]
      ..sort((a, b) {
        final byTransfers = a.transferCount.compareTo(b.transferCount);
        return byTransfers != 0
            ? byTransfers
            : a.totalDurationSeconds.compareTo(b.totalDurationSeconds);
      });
    return sorted.first;
  }

  static JourneyPlan fromJson(Map<String, dynamic> json) {
    final list = (json['journeys'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_journeyFromJson)
        .toList();

    return JourneyPlan(
      journeys: list,
      originLabel: json['originLabel'] as String?,
      destinationLabel: json['destinationLabel'] as String?,
    );
  }

  static PlannedJourney _journeyFromJson(Map<String, dynamic> json) {
    final legs = (json['legs'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_legFromJson)
        .toList();

    return PlannedJourney(
      id: json['id'] as String? ?? '',
      legs: legs,
      // The API sends integer fils, matching the backend money contract.
      totalFare: Money(json['totalFareFils'] as int? ?? 0),
      totalDurationSeconds: json['totalDurationSeconds'] as int? ?? 0,
      walkingMeters: json['walkingMeters'] as int? ?? 0,
      transferCount: json['transferCount'] as int? ?? 0,
      departureTime: parseDate(json['departureTime']),
      journeyId: json['journeyId'] as String?,
      transferDiscountFils: json['transferDiscountFils'] as int? ?? 0,
      freshness: DataFreshness.fromWire(json['freshness'] as String? ?? 'UNKNOWN'),
    );
  }

  static JourneyLeg _legFromJson(Map<String, dynamic> json) {
    return JourneyLeg(
      sequence: json['sequence'] as int? ?? 0,
      mode: TransportMode.fromWire(json['mode'] as String? ?? 'BUS'),
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      fromLabel: json['fromLabel'] as String?,
      toLabel: json['toLabel'] as String?,
      routeName: json['routeName'] as String?,
      departureTime: parseDate(json['departureTime']),
      arrivalTime: parseDate(json['arrivalTime']),
      distanceMeters: json['distanceMeters'] as int? ?? 0,
      fare: Money(json['fareFils'] as int? ?? 0),
    );
  }

  static DateTime? parseDate(Object? value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toLocal();
    }
    return null;
  }

  static Place placeFromJson(Map<String, dynamic> json) => Place(
        id: json['id'] as String? ?? '',
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        nameAm: json['nameAm'] as String?,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        zone: json['zone'] as String?,
        kind: PlaceKind.fromJson(json),
      );

  @override
  List<Object?> get props => [journeys, originLabel, destinationLabel];
}
