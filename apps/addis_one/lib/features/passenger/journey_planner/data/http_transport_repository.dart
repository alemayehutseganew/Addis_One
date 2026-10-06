import '../../../../core/models/journey.dart';
import '../../../../core/models/journey_plan.dart';
import '../../../../core/models/ticket.dart';
import '../../../../core/money.dart';
import '../../../../core/network/api_client.dart';
import '../domain/transport_repository.dart';

/// Transport repository backed by the real Addis One API.
class HttpTransportRepository implements TransportRepository {
  // Private field, public parameter — see ApiClient for the rationale.
  // ignore: prefer_initializing_formals
  HttpTransportRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  @override
  Future<List<Place>> searchPlaces(String query) async {
    // An empty query is a browse, not a search. The server already answers it
    // with a default page of stops, and the picker calls this with no query on
    // open — returning [] here made every fresh picker read "No stops found"
    // without the request ever leaving the phone.
    final term = query.trim();
    final json = await _api.getJson(
      '/stops',
      query: term.isEmpty ? null : {'q': term},
    );
    final list = (json['stops'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(JourneyPlan.placeFromJson)
        .toList();
    return list;
  }

  @override
  Future<List<NearbyStop>> nearbyStops(GeoPoint point) async {
    final json = await _api.getJson('/stops/nearby', query: {
      'lat': point.latitude.toString(),
      'lng': point.longitude.toString(),
      'limit': '5',
    });
    final list = (json['stops'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(
          (row) => NearbyStop(
            place: JourneyPlan.placeFromJson(row),
            // The server computes this. It is not re-derived here: a second
            // haversine on the client could disagree with the one that did the
            // ordering, and the passenger would be shown a distance that does
            // not match the ranking above it.
            distanceMeters: (row['distanceMeters'] as num?)?.round() ?? 0,
          ),
        )
        .toList();
    return list;
  }

  @override
  Future<JourneyPlan> planJourney(JourneyPlanRequest request) async {
    final json = await _api.postJson('/journeys/plan', body: request.toJson());
    return JourneyPlan.fromJson(json);
  }

  @override
  Future<PaymentStartResult> startPayment({
    required Money amount,
    required PaymentMethod method,
    required String idempotencyKey,
    String? journeyId,
  }) async {
    if (journeyId == null || journeyId.isEmpty) {
      // The server verifies the claimed amount against the FareCalculation
      // attached to this journey (revenue protection). Without an id there is
      // nothing to verify against, so failing here gives a clear cause instead
      // of a 404 or a FARE_MISMATCH later.
      throw const ApiException(
        ApiFailure.validation,
        message: 'This journey must be re-planned before it can be bought',
      );
    }

    final json = await _api.postJson('/payments', body: {
      // Integer fils, matching the backend money contract exactly.
      'journeyId': journeyId,
      'amountFils': amount.fils,
      'method': method.wire,
      'idempotencyKey': idempotencyKey,
    });
    return PaymentStartResult.fromJson(json);
  }

  @override
  Future<PaymentStatus> paymentStatus(String paymentId) async {
    final json = await _api.getJson('/payments/$paymentId');
    return PaymentStatus.fromWire(json['status'] as String?);
  }

  @override
  Future<IssuedTicket?> ticketForPayment(String paymentId) async {
    try {
      final json = await _api.getJson('/payments/$paymentId/ticket');
      if (json.isEmpty) return null;
      return IssuedTicket.fromJson(json);
    } on ApiException catch (e) {
      // 404 means "not issued yet", which is a normal intermediate state
      // rather than an error — the caller polls until it resolves.
      if (e.failure == ApiFailure.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<List<IssuedTicket>> myTickets() async {
    final json = await _api.getJson('/tickets/mine');
    return (json['tickets'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(IssuedTicket.fromJson)
        .toList();
  }

  @override
  Future<TripsResult> myTrips() async {
    // Public endpoint, so a signed-out caller gets an empty list rather than a
    // 401 — which is why `signedIn` comes back on the response itself.
    final json = await _api.getJson('/journeys/mine');
    return TripsResult(
      signedIn: json['signedIn'] as bool? ?? false,
      trips: (json['journeys'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(PastTrip.fromJson)
          .toList(),
    );
  }
}
