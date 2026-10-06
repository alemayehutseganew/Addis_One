import 'package:equatable/equatable.dart';

import '../money.dart';
import 'journey.dart';

/// Operational status of a vehicle, mirroring the backend `VehicleStatus`.
///
/// This is carried on the profile rather than inferred, because "the code is
/// known but the vehicle is RETIRED" is a different answer to the passenger than
/// "the code is not known" — and only the server can tell those apart.
enum VehicleStatus {
  active('ACTIVE'),
  maintenance('MAINTENANCE'),
  outOfService('OUT_OF_SERVICE'),
  retired('RETIRED');

  const VehicleStatus(this.wire);
  final String wire;

  bool get canAcceptPassengers => this == VehicleStatus.active;

  /// A vehicle that exists but cannot legally sell a ticket right now.
  ///
  /// Worth distinguishing from "not found": the passenger has typed a real,
  /// correctly spelled code and is being turned away by the operator's own
  /// fleet state, not by a typo. Those two need different advice.
  bool get isTemporarilyUnavailable =>
      this == VehicleStatus.maintenance || this == VehicleStatus.outOfService;

  static VehicleStatus fromWire(String? value) {
    return VehicleStatus.values.firstWhere(
      (s) => s.wire == value,
      orElse: () => VehicleStatus.active,
    );
  }
}

/// A vehicle found by its code, with everything needed to authorise a purchase.
///
/// This is what steps 4–5 of the flow display. The fare is server-computed and
/// arrives with the profile; the client never derives it, for the same reason
/// it never derives a journey fare — a client/server divergence is how a
/// passenger gets charged an amount no conductor can explain.
class VehicleProfile extends Equatable {
  const VehicleProfile({
    required this.vehicleId,
    required this.code,
    required this.routeLabel,
    required this.operatorName,
    required this.fare,
    required this.status,
    this.plateNumber,
    this.mode = TransportMode.bus,
    // Defaulted to empty rather than nullable: the getters below treat "no
    // translation supplied" and "translation is the empty string" identically,
    // and a nullable String would force every call site to handle both.
    this.routeLabelAm = '',
    this.operatorNameAm = '',
    this.capacity,
    this.boardingStopLabel,
    this.boardingDistanceMeters,
  });

  final String vehicleId;

  /// The code the passenger typed, normalised to upper case by the server.
  final String code;

  /// e.g. "Route 7 — Piazza ⇄ Bole"
  final String routeLabel;
  final String routeLabelAm;

  final String operatorName;
  final String operatorNameAm;

  /// Authoritative fare for boarding this vehicle. Integer fils.
  final Money fare;

  /// Stop the passenger was priced from, when the fare is distance-based.
  ///
  /// Null when the server quoted a flat fare — typically because no usable
  /// position was supplied. The distinction matters to the passenger: a fare
  /// that came from "you are near Piazza" and one that came from nowhere are not
  /// the same claim, and showing the stop is what lets them check it.
  final String? boardingStopLabel;

  /// How far the passenger was from [boardingStopLabel], in metres.
  ///
  /// Present only alongside [boardingStopLabel]. This is the *distance to the
  /// boarding point*, not the length of the ride — the ride's distance is not
  /// known until the passenger gets off.
  final int? boardingDistanceMeters;

  /// True when the server priced this fare from a position rather than a flat
  /// rate.
  bool get isDistanceBased => boardingDistanceMeters != null;

  /// How the fare was arrived at, for display under the price.
  ///
  /// Empty rather than null so the caller can render the string directly
  /// without a null branch at every call site.
  String fareBasisFor(bool amharic) {
    if (!isDistanceBased) {
      return amharic ? 'የተረከዘ ክፍያ' : 'Flat fare';
    }
    final stop = boardingStopLabel ?? '';
    final metres = boardingDistanceMeters!;
    final away = metres >= 1000
        ? '${(metres / 1000).toStringAsFixed(1)} km'
        : '$metres m';
    return amharic
        ? 'ከ$stop $away የርቀት'
        : 'Distance fare · $away from $stop';
  }

  final VehicleStatus status;
  final String? plateNumber;
  final TransportMode mode;
  final int? capacity;

  /// Both the code and the fleet state must pass before money moves. A ticket
  /// sold to a vehicle in the garage is a ticket nobody can validate.
  bool get isPurchasable => status.canAcceptPassengers && fare.isPositive;

  /// The Amharic label when one was supplied, else the English one.
  ///
  /// Falls back rather than rendering an empty row: a partially translated
  /// record is still better than a blank on the screen the passenger is
  /// deciding whether to pay on.
  String routeLabelFor(bool amharic) => amharic && routeLabelAm.isNotEmpty
      ? routeLabelAm
      : routeLabel;

  String operatorNameFor(bool amharic) => amharic && operatorNameAm.isNotEmpty
      ? operatorNameAm
      : operatorName;

  /// Parses the vehicle shape the API returns.
  ///
  /// Tolerant on purpose: a field the server adds later must not blank out the
  /// whole screen, and a field it omits must not crash the lookup. The fare
  /// defaults to zero, which fails `isPurchasable`, so an incomplete record can
  /// never be bought by accident.
  static VehicleProfile fromJson(Map<String, dynamic> json) {
    return VehicleProfile(
      vehicleId: json['vehicleId'] as String? ?? json['id'] as String? ?? '',
      code: (json['code'] as String? ?? json['vehicleCode'] as String? ?? '')
          .toUpperCase(),
      routeLabel: json['routeLabel'] as String? ?? json['route'] as String? ?? '—',
      routeLabelAm: json['routeLabelAm'] as String? ?? '',
      operatorName:
          json['operatorName'] as String? ?? json['operator'] as String? ?? '—',
      operatorNameAm: json['operatorNameAm'] as String? ?? '',
      fare: Money(json['fareFils'] as int? ?? 0),
      status: VehicleStatus.fromWire(json['status'] as String?),
      plateNumber: json['plateNumber'] as String?,
      mode: TransportMode.fromWire(json['mode'] as String? ?? 'BUS'),
      capacity: (json['capacity'] as num?)?.round(),
      // Distance pricing is optional on the wire: a server that quoted a flat
      // fare sends neither field, and the UI falls back to saying so rather
      // than rendering an empty stop row.
      boardingStopLabel: json['boardingStopLabel'] as String?,
      boardingDistanceMeters: (json['boardingDistanceMeters'] as num?)?.round(),
    );
  }

  /// Returns a copy with the server's distance-based quote applied.
  ///
  /// Exists so the fare and the explanation of the fare can never drift apart:
  /// they arrive together from one response and are written together here.
  VehicleProfile withDistanceQuote({
    required String stopLabel,
    required int distanceMeters,
    required Money quotedFare,
  }) {
    return VehicleProfile(
      vehicleId: vehicleId,
      code: code,
      routeLabel: routeLabel,
      routeLabelAm: routeLabelAm,
      operatorName: operatorName,
      operatorNameAm: operatorNameAm,
      fare: quotedFare,
      status: status,
      plateNumber: plateNumber,
      mode: mode,
      capacity: capacity,
      boardingStopLabel: stopLabel,
      boardingDistanceMeters: distanceMeters,
    );
  }

  @override
  List<Object?> get props => [
        vehicleId,
        code,
        routeLabel,
        operatorName,
        fare,
        status,
        boardingStopLabel,
        boardingDistanceMeters,
      ];
}