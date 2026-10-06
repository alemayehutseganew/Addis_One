import 'dart:math' as math;

import '../../../../core/models/journey.dart';
import '../../../../core/models/qr_credential.dart';
import '../../../../core/models/ticket.dart';
import '../../../../core/models/ticket_validation.dart';
import '../../../../core/models/vehicle.dart';
import '../../../../core/money.dart';
import '../domain/vehicle_repository.dart';

/// Vehicle-code data source used when the build is flagged USE_DEMO_DATA=true.
///
/// Mirrors the live repository's contract exactly — including returning null for
/// an unknown code rather than inventing one — so the flow being exercised in a
/// demo build is the flow that will run live. A demo repository that threw, or
/// always found a vehicle, would hide the "Vehicle Not Found" branch that half
/// the blueprint is about.
///
/// The credential signature is obviously not real. A demo ticket would be
/// rejected by a genuine validator, which is the correct and honest outcome.
class DemoVehicleRepository implements VehicleRepository {
  static const Duration _latency = Duration(milliseconds: 300);

  static const _vehicles = <VehicleProfile>[
    VehicleProfile(
      vehicleId: 'veh-001',
      code: 'AA 12345',
      routeLabel: 'Route 7 — Piazza ⇄ Bole',
      routeLabelAm: 'መስመር 7 — ፓያዛ ⇄ ቦሌ',
      operatorName: 'Blue Nile Transport',
      operatorNameAm: 'ነጭ ናይል ትራንስፖርት',
      fare: Money(1500),
      status: VehicleStatus.active,
      plateNumber: 'AA 12345',
      capacity: 45,
    ),
    VehicleProfile(
      vehicleId: 'veh-002',
      code: 'AA 67890',
      routeLabel: 'Route 3 — Megenagna ⇄ Piazza',
      routeLabelAm: 'መስመር 3 — መገናኛ ⇄ ፓያዛ',
      operatorName: 'Sheba Transport',
      operatorNameAm: 'ሸባ ትራንስፖርት',
      fare: Money(1200),
      status: VehicleStatus.active,
      plateNumber: 'AA 67890',
      capacity: 30,
    ),
    // Present on purpose so the "known vehicle, cannot sell a ticket" branch is
    // reachable in a demo build rather than only in production.
    VehicleProfile(
      vehicleId: 'veh-003',
      code: 'AA 99999',
      routeLabel: 'Route 12 — Airport',
      routeLabelAm: 'መስመር 12 — አየር መንገስ',
      operatorName: 'Sheba Transport',
      operatorNameAm: 'ሸባ ትራንስፖርት',
      fare: Money(3000),
      status: VehicleStatus.maintenance,
      plateNumber: 'AA 99999',
      capacity: 55,
    ),
  ];

  /// Stops each demo route runs through, used only to price a distance quote.
  ///
  /// Real coordinates around Addis Ababa. The live build never sees these — the
  /// server owns its own stop table — but a demo that cannot answer "which stop
  /// are you near, and what does that cost" would leave the whole distance-pricing
  /// branch unreachable.
  static const _routeStops = <String, List<_RouteStop>>{
    'AA 12345': [
      _RouteStop('Piazza', 9.0192, 38.7525),
      _RouteStop('Meskel', 9.0128, 38.7580),
      _RouteStop('Arat Kilo', 9.0350, 38.7400),
      _RouteStop('Bole', 9.0400, 38.7410),
    ],
    'AA 67890': [
      _RouteStop('Megenagna', 9.0330, 38.7250),
      _RouteStop('Piazza', 9.0192, 38.7525),
      _RouteStop('Kirkos', 9.0450, 38.7350),
    ],
    'AA 99999': [
      _RouteStop('Airport', 8.9779, 38.7993),
      _RouteStop('Bole', 9.0400, 38.7410),
    ],
  };

  /// Per-kilometre rate added to the flat base when a position is supplied.
  ///
  /// Integer fils, matching [Money]. Rounded up per whole kilometre so the
  /// quote never lands on a fractional fil and never rounds in the operator's
  /// favour at the passenger's expense.
  static const int _filsPerKm = 150;

  /// How far from a route stop the passenger may be and still be priced from it.
  ///
  /// Beyond this the demo falls back to the flat fare, mirroring a server that
  /// will not quote a distance it cannot place. Snapping a passenger in Kilimanjaro
  /// to "Bole" would produce a confidently wrong price.
  static const int _maxSnapMeters = 1500;

  @override
  Future<VehicleProfile?> lookupVehicle(
    String code, {
    GeoPoint? boardingPoint,
  }) async {
    await Future<void>.delayed(_latency);
    final needle = code.trim().toUpperCase();
    for (final vehicle in _vehicles) {
      if (vehicle.code.toUpperCase() != needle) continue;

      // No position — permission denied, timed out, or the passenger declined.
      // The flow must still complete, so the flat fare stands.
      if (boardingPoint == null) return vehicle;

      return _quoteForPosition(vehicle, boardingPoint);
    }
    // Null, not an exception: this is the step-3 NO branch.
    return null;
  }

  /// Stands in for the server's distance-based quote.
  ///
  /// In production this arithmetic belongs on the server: the client sends
  /// coordinates and renders whatever comes back. It lives here only so a demo
  /// build can exercise the branch end to end.
  VehicleProfile _quoteForPosition(VehicleProfile vehicle, GeoPoint point) {
    final stops = _routeStops[vehicle.code];
    if (stops == null || stops.isEmpty) return vehicle;

    var nearest = stops.first;
    var nearestMetres = double.infinity;
    for (final stop in stops) {
      final metres = _haversineMeters(
        point.latitude,
        point.longitude,
        stop.latitude,
        stop.longitude,
      );
      if (metres < nearestMetres) {
        nearest = stop;
        nearestMetres = metres;
      }
    }

    if (nearestMetres > _maxSnapMeters) return vehicle;

    final rounded = nearestMetres.round();
    final extraKm = (rounded / 1000).ceil();
    final quoted = Money(vehicle.fare.fils + extraKm * _filsPerKm);

    return vehicle.withDistanceQuote(
      stopLabel: nearest.label,
      distanceMeters: rounded,
      quotedFare: quoted,
    );
  }

  /// Great-circle metres. Same approximation the transport demo uses, so the
  /// two never disagree about which stop is closest.
  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    double toRad(double deg) => deg * math.pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return earthRadius * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  @override
  Future<PaymentStartResult> startVehiclePayment({
    required VehicleProfile vehicle,
    required Money amount,
    required int quantity,
    required PaymentMethod method,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(_latency);
    // The quantity is recorded so a demo purchase of four actually yields four
    // tickets — a demo that ignored it would misrepresent the group flow the
    // live build performs.
    _lastQuantity = quantity;
    // Mirrors the real provider shape: settling without a redirect is a valid
    // outcome, and still not something the client assumes — the controller
    // polls payment status and the ticket endpoint regardless.
    return PaymentStartResult(
      paymentId: 'vp-demo-$idempotencyKey',
      reference: 'VP-DEMO-${idempotencyKey.substring(0, 8).toUpperCase()}',
      status: PaymentStatus.confirmed,
      redirectUrl: null,
    );
  }

  @override
  Future<PaymentStatus> vehiclePaymentStatus(String paymentId) async {
    await Future<void>.delayed(_latency);
    return PaymentStatus.confirmed;
  }

  @override
  Future<List<IssuedTicket>> ticketsForVehiclePayment(String paymentId) async {
    await Future<void>.delayed(_latency);
    // One ticket per passenger, each with its own credential. Interchangeable,
    // so they are distinguished only by index — there are no names anywhere in
    // this model, by design.
    final count = _lastQuantity < 1 ? 1 : _lastQuantity;
    return List<IssuedTicket>.generate(count, (index) => _demoTicket(index));
  }

  @override
  Future<List<TicketValidationRecord>> ticketValidations(
    String ticketId,
  ) async {
    await Future<void>.delayed(_latency);
    return List<TicketValidationRecord>.from(_ledger[ticketId] ?? const []);
  }

  @override
  Future<ValidationOutcome> recordValidation({
    required String ticketId,
    required ValidationKind kind,
    String? tripId,
  }) async {
    await Future<void>.delayed(_latency);
    final ledger = _ledger.putIfAbsent(ticketId, () => []);

    // Mirrors the server's rule rather than being permissive: entry is allowed
    // exactly once, exit only after an entry. A demo that accepted anything
    // would not exercise the refusals that stop a fare being reused.
    final alreadyEntry = ledger.any((r) => r.kind == ValidationKind.entry);
    final alreadyExit = ledger.any((r) => r.kind == ValidationKind.exit);

    if (kind == ValidationKind.entry && alreadyEntry) {
      return AlreadyScannedAt(
        kind: kind,
        firstScanAt: ledger.firstWhere((r) => r.kind == ValidationKind.entry).scannedAt,
      );
    }
    if (kind == ValidationKind.exit && alreadyExit) {
      return AlreadyScannedAt(
        kind: kind,
        firstScanAt: ledger.firstWhere((r) => r.kind == ValidationKind.exit).scannedAt,
      );
    }
    if (kind == ValidationKind.exit && !alreadyEntry) {
      return const ExitWithoutEntry();
    }

    final record = TicketValidationRecord(
      kind: kind,
      scannedAt: DateTime.now(),
      tripId: tripId,
      deviceId: 'demo-device',
    );
    ledger.add(record);

    return kind == ValidationKind.entry
        ? EntryAccepted(record: record)
        : ExitAccepted(record: record);
  }

  /// Scans recorded per ticket, so a demo shows the same entry/exit lifecycle a
  /// live build does rather than a single flag flipping.
  final Map<String, List<TicketValidationRecord>> _ledger = {};

  @override
  Future<IssuedTicket?> refreshTicket(String ticketId) async {
    await Future<void>.delayed(_latency);
    return _demoTicket(0);
  }

  /// Quantity of the most recent payment, used to size the demo ticket batch.
  int _lastQuantity = 1;

  IssuedTicket _demoTicket(int index) {
    final now = DateTime.now();
    final expires = now.add(const Duration(hours: 2));
    final id = 'demo-vehicle-ticket-$index';
    return IssuedTicket(
      id: id,
      reference: 'TKT-DEMO-VEH-${index + 1}',
      status: TicketStatus.valid,
      issuedAt: now,
      expiresAt: expires,
      fare: const Money(1500),
      mode: 'BUS',
      credential: QrCredential(
        ticketId: id,
        credentialId: 'demo-vehicle-credential-$index',
        issuedAt: now.millisecondsSinceEpoch ~/ 1000,
        expiresAt: expires.millisecondsSinceEpoch ~/ 1000,
        nonce: 'demovehiclecredentialn$index'.padRight(24, '0'),
        keyId: 'demo-key',
        signature: 'RGVtby12ZWhpY2xlLXNpZ25hdHVyZS1ub3QtcmVhbA==',
      ),
    );
  }
}

/// One stop on a demo route, with just enough to price a boarding point.
class _RouteStop {
  const _RouteStop(this.label, this.latitude, this.longitude);

  final String label;
  final double latitude;
  final double longitude;
}