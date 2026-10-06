import 'dart:math' as math;

import '../../../../core/models/journey.dart';
import '../../../../core/models/journey_plan.dart';
import '../../../../core/models/qr_credential.dart';
import '../../../../core/models/ticket.dart';
import '../../../../core/money.dart';
import '../domain/transport_repository.dart';

/// Local data source used when the build is flagged with USE_DEMO_DATA=true.
///
/// This exists because the backend HTTP layer is not built yet, not to fake a
/// working system: the flag is surfaced in the UI so a demo build can never be
/// mistaken for one talking to production.
class DemoTransportRepository implements TransportRepository {
  static const bool isDemoData = true;

  /// Simulated provider latency, so loading states are actually exercised.
  static const Duration _latency = Duration(milliseconds: 350);

  static const _places = <Place>[
    Place(id: 'stop-piazza', code: 'PZA', name: 'Piazza', nameAm: 'ፓያዛ', latitude: 9.0300, longitude: 38.7400, zone: 'Z1'),
    Place(id: 'stop-bole', code: 'BOL', name: 'Bole', nameAm: 'ቦሌ', latitude: 9.0100, longitude: 38.7900, zone: 'Z3'),
    Place(id: 'station-lawn', code: 'LW', name: 'La Gare', nameAm: 'ላ ጋር', kind: PlaceKind.station, latitude: 9.0250, longitude: 38.7500),
    Place(id: 'stop-megenagna', code: 'MEG', name: 'Megenagna', nameAm: 'መገናኛ', latitude: 9.0200, longitude: 38.7600, zone: 'Z2'),
    Place(id: 'stop-arada', code: 'ARD', name: 'Arada', nameAm: 'አራዳ', latitude: 9.0150, longitude: 38.7450, zone: 'Z2'),
  ];

  @override
 Future<List<Place>> searchPlaces(String query) async {
    await Future<void>.delayed(_latency);
    final q = query.trim().toLowerCase();
    // Browse on an empty query, mirroring the live repository and the server.
    if (q.isEmpty) return _places;
    return _places
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            (p.nameAm?.contains(query.trim()) ?? false) ||
            p.code.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<List<NearbyStop>> nearbyStops(GeoPoint point) async {
    await Future<void>.delayed(_latency);
    final withCoords = _places
        .where((p) => p.latitude != null && p.longitude != null)
        .map((p) {
          final metres = _haversineMeters(
            point.latitude,
            point.longitude,
            p.latitude!,
            p.longitude!,
          );
          return NearbyStop(place: p, distanceMeters: metres.round());
        })
        .toList()
      // Sorted by the computed distance rather than the seed order, so the demo
      // build resolves "near me" the same way the live one does.
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return withCoords.take(5).toList();
  }

  /// Great-circle metres. Matches the server's approximation to well under the
  /// precision of a GPS fix, so demo and live give the same ordering.
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
  Future<JourneyPlan> planJourney(JourneyPlanRequest request) async {
    await Future<void>.delayed(_latency);
    final origin = request.origin;
    final destination = request.destination;

    final busMinutes = _minutesBetween(origin, destination);

    // Deliberately varied so the cheapest / fastest / simplest highlights on
    // the results screen have something to disagree about.
    final journeys = <PlannedJourney>[
      PlannedJourney(
        id: 'demo-direct',
        legs: [
          JourneyLeg(
            sequence: 0,
            mode: TransportMode.walk,
            durationSeconds: 300,
            fromLabel: origin.name,
            toLabel: 'Stop',
            distanceMeters: 210,
          ),
          JourneyLeg(
            sequence: 1,
            mode: TransportMode.bus,
            durationSeconds: busMinutes * 60,
            fromLabel: 'Stop',
            toLabel: destination.name,
            routeName: 'Route 12',
            distanceMeters: 5200,
            fare: const Money(1500),
          ),
          JourneyLeg(
            sequence: 2,
            mode: TransportMode.walk,
            durationSeconds: 240,
            fromLabel: 'Stop',
            toLabel: destination.name,
            distanceMeters: 210,
          ),
        ],
        totalFare: const Money(1500),
        totalDurationSeconds: (busMinutes * 60) + 540,
        walkingMeters: 420,
        transferCount: 0,
        departureTime: request.departureTime,
      ),
      PlannedJourney(
        id: 'demo-express',
        legs: [
          JourneyLeg(
            sequence: 0,
            mode: TransportMode.taxi,
            durationSeconds: (busMinutes * 60) ~/ 2,
            fromLabel: origin.name,
            toLabel: destination.name,
            distanceMeters: 6100,
            fare: const Money(3200),
          ),
        ],
        totalFare: const Money(3200),
        totalDurationSeconds: (busMinutes * 60) ~/ 2,
        walkingMeters: 0,
        transferCount: 0,
        departureTime: request.departureTime,
      ),
      PlannedJourney(
        id: 'demo-transfer',
        legs: [
          JourneyLeg(
            sequence: 0,
            mode: TransportMode.walk,
            durationSeconds: 280,
            fromLabel: origin.name,
            toLabel: 'Stop',
            distanceMeters: 300,
          ),
          JourneyLeg(
            sequence: 1,
            mode: TransportMode.bus,
            durationSeconds: busMinutes * 30,
            fromLabel: 'Stop',
            toLabel: 'Megenagna',
            routeName: 'Route 3',
            distanceMeters: 3100,
            fare: const Money(1000),
          ),
          JourneyLeg(
            sequence: 2,
            mode: TransportMode.bus,
            durationSeconds: busMinutes * 30,
            fromLabel: 'Megenagna',
            toLabel: destination.name,
            routeName: 'Route 7',
            distanceMeters: 2900,
            fare: const Money(1000),
          ),
        ],
        // Transfer discount: two legs priced below their sum, as the backend
        // transfer rules would produce.
        totalFare: const Money(1800),
        totalDurationSeconds: (busMinutes * 60) + 900,
        walkingMeters: 700,
        transferCount: 1,
        departureTime: request.departureTime,
      ),
    ];

    return JourneyPlan(
      journeys: journeys,
      originLabel: origin.name,
      destinationLabel: destination.name,
    );
  }

  /// Crude but stable estimate from straight-line distance, so the same pair
  /// always produces the same durations.
  int _minutesBetween(Place a, Place b) {
    final lat = (a.latitude ?? 9.03) - (b.latitude ?? 9.03);
    final lng = (a.longitude ?? 38.74) - (b.longitude ?? 38.74);
    final km = (lat * lat + lng * lng) * 9400; // ~111 km per degree
    final minutes = (km * 3 + 6).round();
    return minutes < 5 ? 5 : minutes;
  }

  @override
  Future<PaymentStartResult> startPayment({
    required Money amount,
    required PaymentMethod method,
    required String idempotencyKey,
    String? journeyId,
  }) async {
    await Future<void>.delayed(_latency);
    // Mirrors the real provider shape: settling without a redirect is a valid
    // outcome, and still not something the client should assume — the caller
    // polls payment status and the ticket endpoint regardless.
    return PaymentStartResult(
      paymentId: 'demo-$idempotencyKey',
      reference: 'PAY-DEMO-${idempotencyKey.substring(0, 8).toUpperCase()}',
      status: PaymentStatus.confirmed,
      redirectUrl: null,
    );
  }

  @override
  Future<PaymentStatus> paymentStatus(String paymentId) async {
    await Future<void>.delayed(_latency);
    return PaymentStatus.confirmed;
  }

  @override
  Future<IssuedTicket?> ticketForPayment(String paymentId) async {
    await Future<void>.delayed(_latency);
    return _demoTicket();
  }

  @override
  Future<TripsResult> myTrips() async {
    // The demo repository has no history to show, and says so rather than
    // inventing journeys — a fake trip list is worse than an empty one.
    return const TripsResult(trips: [], signedIn: true);
  }

  @override
  Future<List<IssuedTicket>> myTickets() async {
    await Future<void>.delayed(_latency);
    return [_demoTicket()];
  }

  /// Demo credential. The signature is obviously not real — this ticket would
  /// be rejected by a genuine validator, which is correct: demo data must never
  /// masquerade as something the backend signed.
  IssuedTicket _demoTicket() {
    final now = DateTime.now();
    final expires = now.add(const Duration(hours: 2));
    return IssuedTicket(
      id: 'demo-ticket',
      reference: 'TKT-DEMO-0001',
      status: TicketStatus.valid,
      issuedAt: now,
      expiresAt: expires,
      fare: const Money(1500),
      mode: 'BUS',
      credential: QrCredential(
        ticketId: 'demo-ticket',
        credentialId: 'demo-credential',
        issuedAt: now.millisecondsSinceEpoch ~/ 1000,
        expiresAt: expires.millisecondsSinceEpoch ~/ 1000,
        nonce: 'demodemonstrationnonce00',
        keyId: 'demo-key',
        signature: 'RGVtby1zaWduYXR1cmUtbm90LWEtcmVhbC1zaWduYXR1cmU=',
      ),
    );
  }
}
