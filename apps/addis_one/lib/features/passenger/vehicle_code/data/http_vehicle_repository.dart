import '../../../../core/models/journey.dart';
import '../../../../core/models/ticket.dart';
import '../../../../core/models/ticket_validation.dart';
import '../../../../core/models/vehicle.dart';
import '../../../../core/money.dart';
import '../../../../core/network/api_client.dart';
import '../../journey_planner/domain/transport_repository.dart';
import '../domain/vehicle_repository.dart';

/// Vehicle-code repository backed by the real Addis One API.
///
/// Endpoints (`/vehicles/code/:code`, `/vehicle-payments`) are the client-side
/// contract this flow requires. They are implemented here against the shapes the
/// rest of the API already uses — integer fils, the same `qrString` credential,
/// the same payment envelope — so wiring the server side up later is a
/// controller, not a client rewrite.
class HttpVehicleRepository implements VehicleRepository {
  // Private field, public parameter — see ApiClient for the rationale.
  // ignore: prefer_initializing_formals
  HttpVehicleRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  @override
  Future<VehicleProfile?> lookupVehicle(
    String code, {
    GeoPoint? boardingPoint,
  }) async {
    try {
      // The position rides along as query parameters rather than in the path, so
      // the same URL identifies the vehicle either way and a server that does
      // not support distance pricing yet simply ignores them and quotes flat.
      final uri = StringBuffer('/vehicles/code/${Uri.encodeComponent(code)}');
      if (boardingPoint != null) {
        uri.write('?lat=${boardingPoint.latitude}&lng=${boardingPoint.longitude}');
      }
      final json = await _api.getJson(uri.toString());

      // A 200 with no `vehicle` key is treated the same as a 404: from the
      // passenger's point of view there is no such vehicle. Distinguishing them
      // would only ever produce a different error for the same real outcome.
      final vehicle = json['vehicle'] as Map<String, dynamic>?;
      if (vehicle == null) return null;
      // The fare, the stop it was priced from, and the distance all come from
      // this one response. The client never recomputes them.
      return VehicleProfile.fromJson(vehicle);
    } on ApiException catch (e) {
      // 404 is the honest "not registered" answer. Throwing it as an error
      // would make step 3's NO branch indistinguishable from an outage.
      if (e.failure == ApiFailure.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<PaymentStartResult> startVehiclePayment({
    required VehicleProfile vehicle,
    required Money amount,
    required int quantity,
    required PaymentMethod method,
    required String idempotencyKey,
  }) async {
    if (vehicle.vehicleId.isEmpty) {
      throw const ApiException(
        ApiFailure.validation,
        message: 'This vehicle must be looked up again before it can be paid for',
      );
    }

    final json = await _api.postJson('/vehicle-payments', body: {
      'vehicleId': vehicle.vehicleId,
      // Integer fils, matching the backend money contract exactly. This is the
      // TOTAL for the group, not the per-person fare.
      'amountFils': amount.fils,
      // The server issues one ticket per unit. It is sent rather than inferred
      // from the amount: a client that quietly derived it would let a
      // tampered client ask for four tickets at the price of one.
      'quantity': quantity,
      'method': method.wire,
      'idempotencyKey': idempotencyKey,
    });
    return PaymentStartResult.fromJson(json);
  }

  @override
  Future<PaymentStatus> vehiclePaymentStatus(String paymentId) async {
    final json = await _api.getJson('/vehicle-payments/$paymentId');
    return PaymentStatus.fromWire(json['status'] as String?);
  }

  @override
  Future<List<IssuedTicket>> ticketsForVehiclePayment(String paymentId) async {
    try {
      final json = await _api.getJson('/vehicle-payments/$paymentId/tickets');

      // Accept both shapes: a group booking returns a list, while a
      // single-ticket response may still be a bare object. Parsing only the
      // list shape would make a valid single ticket look like none issued.
      final list = json['tickets'] as List?;
      if (list != null) {
        return list
            .cast<Map<String, dynamic>>()
            .map(IssuedTicket.fromJson)
            .toList();
      }

      final single = json['ticket'];
      if (single is Map<String, dynamic>) {
        return [IssuedTicket.fromJson(single)];
      }
      return const [];
    } on ApiException catch (e) {
      // 404 means "not issued yet", a normal intermediate state rather than an
      // error — the caller polls until it resolves.
      if (e.failure == ApiFailure.notFound) return const [];
      rethrow;
    }
  }

  @override
  Future<List<TicketValidationRecord>> ticketValidations(
    String ticketId,
  ) async {
    try {
      final json = await _api.getJson('/tickets/$ticketId/validations');
      final list = json['validations'] as List? ?? const [];
      return list
          .cast<Map<String, dynamic>>()
          .map(TicketValidationRecord.fromJson)
          .whereType<TicketValidationRecord>()
          .toList();
    } on ApiException catch (e) {
      // An undeployed ledger endpoint means "no scans recorded yet", not a
      // problem with the passenger's ticket. The QR must stay showable.
      if (e.failure == ApiFailure.notFound ||
          e.statusCode == 405 ||
          e.failure == ApiFailure.server) {
        return const [];
      }
      rethrow;
    }
  }

  @override
  Future<ValidationOutcome> recordValidation({
    required String ticketId,
    required ValidationKind kind,
    String? tripId,
  }) async {
    final json = await _api.postJson(
      '/tickets/$ticketId/validations',
      body: {
        'kind': kind.wire,
        if (tripId != null && tripId.isNotEmpty) 'tripId': tripId,
      },
    );
    return validationOutcomeFromJson(json);
  }

  @override
  Future<IssuedTicket?> refreshTicket(String ticketId) async {
    try {
      final json = await _api.getJson('/tickets/$ticketId');
      if (json.isEmpty) return null;
      return IssuedTicket.fromJson(json);
    } on ApiException catch (e) {
      // The endpoint is optional. A server without it answers 404/405, and
      // that must not be reported to the passenger as a problem with their
      // ticket — the QR they already hold remains valid either way.
      if (e.failure == ApiFailure.notFound ||
          e.statusCode == 405 ||
          e.failure == ApiFailure.server) {
        return null;
      }
      rethrow;
    }
  }
}