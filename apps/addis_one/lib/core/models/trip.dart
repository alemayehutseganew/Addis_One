import 'package:equatable/equatable.dart';

/// One ticket on a trip's manifest.
class ManifestTicket extends Equatable {
  const ManifestTicket({
    required this.reference,
    required this.status,
    this.passengerName = '',
    this.mode = '',
    this.issuedAt,
    this.expiresAt,
  });

  factory ManifestTicket.fromJson(Map<String, dynamic> json) => ManifestTicket(
        reference: '${json['reference'] ?? ''}',
        status: '${json['status'] ?? ''}',
        passengerName: '${json['passengerName'] ?? ''}',
        mode: '${json['mode'] ?? ''}',
        issuedAt: Trip._dateOrNull(json['issuedAt']),
        expiresAt: Trip._dateOrNull(json['expiresAt']),
      );

  final String reference;
  final String status;
  final String passengerName;
  final String mode;
  final DateTime? issuedAt;
  final DateTime? expiresAt;

  @override
  List<Object?> get props =>
      [reference, status, passengerName, mode, issuedAt, expiresAt];
}

/// The conductor's view of who is on a trip.
///
/// The counts come from the server rather than being computed here. A handheld
/// that recounted from a truncated page would report a different number from the
/// one the server uses, and the two would be compared against each other during
/// an investigation.
class TripManifest extends Equatable {
  const TripManifest({
    required this.tripId,
    required this.status,
    required this.ticketCount,
    required this.validatedCount,
    required this.tickets,
  });

  factory TripManifest.fromJson(Map<String, dynamic> json) {
    final raw = json['tickets'];
    return TripManifest(
      tripId: '${json['tripId'] ?? ''}',
      status: '${json['status'] ?? ''}',
      ticketCount: (json['ticketCount'] as num?)?.toInt() ?? 0,
      validatedCount: (json['validatedCount'] as num?)?.toInt() ?? 0,
      tickets: [
        if (raw is List)
          for (final t in raw)
            if (t is Map) ManifestTicket.fromJson(Map<String, dynamic>.from(t)),
      ],
    );
  }

  final String tripId;
  final String status;
  final int ticketCount;
  final int validatedCount;
  final List<ManifestTicket> tickets;

  /// Tickets issued but not yet validated — the conductor's open work.
  int get outstanding => (ticketCount - validatedCount).clamp(0, ticketCount);

  @override
  List<Object?> get props =>
      [tripId, status, ticketCount, validatedCount, tickets];
}

/// A trip assigned to this officer.
///
/// ## Why this carries [availableTransitions]
///
/// The server sends, on every trip, the set of statuses that trip may legally
/// move to next, computed from its own state machine. This model keeps that list
/// rather than re-deriving it, and [canStart]/[canComplete] read it.
///
/// The reason is the `canValidate` bug this app already had: a client that keeps
/// its own copy of a server rule will drift from it, and the drift shows an
/// officer a button the server refuses — or, worse, hides a button it permits. An
/// earlier version of this screen hard-coded the status set and, because
/// `BOARDING` and `DELAYED` were missing from that copy, offered a driver no
/// controls at all on a trip the server would have let them depart.
class Trip extends Equatable {
  const Trip({
    required this.id,
    required this.status,
    required this.availableTransitions,
    this.routeName = '',
    this.routeCode = '',
    this.direction = '',
    this.vehiclePlate = '',
    this.tripSequence,
    this.scheduledDeparture,
    this.actualDeparture,
    this.actualArrival,
    this.delaySeconds,
  });

  factory Trip.fromJson(Map<String, dynamic> json) {
    return Trip(
      id: '${json['id'] ?? ''}',
      status: '${json['status'] ?? ''}',
      // Read as a set of strings and kept as one: an absent list means "nothing
      // is permitted", not "everything is". Defaulting to permissive here would
      // offer buttons for a trip that is already finished.
      availableTransitions: _stringList(json['availableTransitions']),
      routeName: '${json['routeName'] ?? ''}',
      routeCode: '${json['routeCode'] ?? ''}',
      direction: '${json['direction'] ?? ''}',
      vehiclePlate: '${json['vehiclePlate'] ?? ''}',
      tripSequence: (json['tripSequence'] as num?)?.toInt(),
      scheduledDeparture: _dateOrNull(json['scheduledDeparture']),
      actualDeparture: _dateOrNull(json['actualDeparture']),
      actualArrival: _dateOrNull(json['actualArrival']),
      delaySeconds: (json['delaySeconds'] as num?)?.toInt(),
    );
  }

  static Set<String> _stringList(dynamic raw) {
    if (raw is! List) return const {};
    return {
      for (final v in raw)
        if (v is String && v.isNotEmpty) v,
    };
  }

  /// An absent or unparseable timestamp reads as null rather than throwing.
  ///
  /// A malformed date on one trip must not stop an officer seeing the rest of
  /// their day, and a zero-epoch date is worse than an absent one — it would
  /// render as a trip that departed in 1970.
  static DateTime? _dateOrNull(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  final String id;
  final String status;
  final Set<String> availableTransitions;
  final String routeName;
  final String routeCode;
  final String direction;
  final String vehiclePlate;
  final int? tripSequence;
  final DateTime? scheduledDeparture;
  final DateTime? actualDeparture;
  final DateTime? actualArrival;
  final int? delaySeconds;

  /// The server permits departing from this state.
  ///
  /// Both source states are honoured because the server's own rule is
  /// "SCHEDULED or BOARDING may become IN_PROGRESS", and a driver whose trip has
  /// already reached BOARDING has not yet departed.
  bool get canStart =>
      availableTransitions.contains('BOARDING') ||
      availableTransitions.contains('IN_PROGRESS');

  /// The server permits completing from this state.
  bool get canComplete => availableTransitions.contains('COMPLETED');

  /// Whether this trip is finished or abandoned, for the purposes of showing
  /// "no actions available" rather than offering one.
  bool get isFinished =>
      availableTransitions.isEmpty &&
      (status == 'COMPLETED' || status == 'CANCELLED');

  /// Whether the client holds enough of a record to act on it.
  ///
  /// Without an id there is no route to call, so the buttons are withheld rather
  /// than offered and failing.
  bool get isActionable => id.isNotEmpty;

  /// `R-3 · Piazza → Kirkos`, or the code when the route is unnamed.
  String get label {
    if (routeName.isEmpty) return routeCode.isEmpty ? 'Trip' : routeCode;
    if (direction.isEmpty) return routeName;
    return '$routeName · $direction';
  }

  @override
  List<Object?> get props => [
        id,
        status,
        availableTransitions,
        routeName,
        routeCode,
        direction,
        vehiclePlate,
        tripSequence,
        scheduledDeparture,
        actualDeparture,
        actualArrival,
        delaySeconds,
      ];
}