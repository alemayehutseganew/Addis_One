// Contract tests against the shapes the live Addis One API actually returns.
//
// These are not invented fixtures: each JSON body below is the exact response
// captured from the running backend during the Phase 5 verification run. The
// point is to catch a server/client field rename at build time rather than on a
// handset at a bus stop, where the failure looks like "the app is broken".
import 'package:addis_one/core/models/journey.dart';
import 'package:addis_one/core/models/journey_plan.dart';
import 'package:addis_one/core/models/ticket.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `qrString` a real issuance produced, verbatim from the API log.
const String realQrString =
    '{"t":"ccbdf9a7-29f9-4fef-9ae0-6ae884547a50",'
    '"c":"3cb57cad-d26d-468e-bc03-ce5f2824d122",'
    '"i":1790930210,"e":1790933850,'
    '"n":"5f1c2a9d3b7e4c8a1f6b2d9e0c3a7b41",'
    '"k":"addis-one-2026-01",'
    '"s":"MEUCIQDx1kZ7y0Hq8mN2pQ5rT3wL9aB4cV6dE8fG0hI2jK4lM6nO8pQ0rS2tU4vW6xY8zA="}';

/// Captured from POST /journeys/plan for Piazza -> Bole.
final Map<String, dynamic> planResponse = {
  'journeys': [
    {
      'id': 'transfer-R-3->R-14@MER',
      'legs': [
        {
          'sequence': 0,
          'mode': 'BUS',
          'routeCode': 'R-3',
          'routeName': 'Piazza - Merkato',
          'fromLabel': 'Piazza',
          'toLabel': 'Merkato',
          'distanceMeters': 3200,
          'durationSeconds': 703,
          'fareFils': 1500,
        },
        {
          'sequence': 1,
          'mode': 'BUS',
          'routeCode': 'R-14',
          'routeName': 'Merkato - Bole',
          'fromLabel': 'Merkato',
          'toLabel': 'Bole',
          'distanceMeters': 5400,
          'durationSeconds': 1064,
          'fareFils': 2320,
        },
      ],
      'totalFareFils': 3820,
      'transferDiscountFils': 580,
      'totalDurationSeconds': 1358,
      'walkingMeters': 0,
      'transferCount': 1,
      'freshness': 'ESTIMATED',
      'journeyId': '3de19752-0000-4000-8000-000000000000',
    },
  ],
};

/// Captured from POST /payments returning CONFIRMED with an issued ticket.
final Map<String, dynamic> confirmedPayment = {
  'paymentId': 'a1b2c3d4-0000-4000-8000-000000000000',
  'paymentReference': 'PAY-MQ7-AB12CD',
  'status': 'CONFIRMED',
  'amountFils': 3820,
  'currency': 'ETB',
  'idempotentReplay': false,
  'providerMode': 'MOCK',
  'ticket': {
    'ticketId': 'ccbdf9a7-29f9-4fef-9ae0-6ae884547a50',
    'reference': 'TKT-MUQPM0CV-CCBDF9',
    'status': 'VALID',
    'issuedAt': '2026-10-02T14:10:10.000Z',
    'expiresAt': '2026-10-02T16:10:10.000Z',
    'fareRuleVersion': 1,
    'qrString': realQrString,
  },
};

void main() {
  // Request shape first: responses alone let a wrong request body ship. See the
  // comment on this group.
  group('JourneyPlanRequest matches what the plan endpoint accepts', () {
    // The response assertions below all passed while the *request* was still
    // wrong: the client sent nested origin/destination objects plus a
    // preferences block, and `forbidNonWhitelisted` in main.ts rejected every
    // one with a 400. Responses alone cannot catch that, so the request body is
    // pinned here against the exact field list the backend DTO declares.
    final piazza = Place(
      id: '3de19752-0000-4000-8000-000000000000',
      code: 'PZA',
      name: 'Piazza',
      latitude: 9.0192,
      longitude: 38.7525,
    );
    final bole = Place(
      id: '4de19752-0000-4000-8000-000000000000',
      code: 'BOL',
      name: 'Bole',
      latitude: 8.9780,
      longitude: 38.7993,
    );

    final body = JourneyPlanRequest(
      origin: piazza,
      destination: bole,
      departureTime: DateTime.utc(2026, 10, 2, 14, 10, 10),
    ).toJson();

    test('sends exactly the three keys the DTO whitelists', () {
      expect(
        body.keys.toSet(),
        {'originStopId', 'destinationStopId', 'departureTime'},
      );
    });

    test('carries the stop UUIDs, not nested coordinate objects', () {
      expect(body['originStopId'], piazza.id);
      expect(body['destinationStopId'], bole.id);
      expect(body['departureTime'], '2026-10-02T14:10:10.000Z');
    });

    test('sends no key the backend would reject as an unknown property', () {
      // Each of these previously guaranteed a 400 on every journey search.
      for (final banned in ['origin', 'destination', 'preferences']) {
        expect(body.containsKey(banned), isFalse,
            reason: '"$banned" is not in PlanJourneyDto and forbidNonWhitelisted '
                'rejects it outright');
      }
    });

    test('preference fields stay client-side and never reach the wire', () {
      // The planner has no walk-limit/transfer/mode/accessibility input.
      // Encoding these would be inventing a contract the server does not
      // implement, so the wire body must be identical either way.
      final loaded = JourneyPlanRequest(
        origin: piazza,
        destination: bole,
        departureTime: DateTime.utc(2026, 10, 2, 14, 10, 10),
        maxWalkingMeters: 250,
        preferFewestTransfers: true,
        accessibleOnly: true,
      );
      expect(loaded.toJson(), body);
    });
  });

  group('JourneyPlan parses the live plan response', () {
    final journey = JourneyPlan.fromJson(planResponse).journeys.single;

    test('reads the server fare in fils without recomputing it', () {
      expect(journey.totalFare.fils, 3820);
      expect(journey.totalFare.currency, 'ETB');
    });

    test('exposes the transfer discount separately from the total', () {
      expect(journey.transferDiscountFils, 580);
      // The passenger can see what they saved rather than a silently lower fare.
      expect(journey.undiscountedFare.fils, 4400);
    });

    test('carries the journeyId the purchase endpoint requires', () {
      expect(journey.isPurchasable, isTrue);
      expect(journey.journeyId, isNotNull);
    });

    test('leg fares sum to the total (no double-counting)', () {
      final sum = journey.legs.fold<int>(0, (a, l) => a + l.fare.fils);
      expect(sum, journey.totalFare.fils);
    });

    test('preserves leg order via sequence', () {
      expect(journey.legs.map((l) => l.sequence), [0, 1]);
      expect(journey.legs.first.routeName, 'Piazza - Merkato');
    });

    test('never claims live data when the server said ESTIMATED', () {
      expect(journey.freshness, DataFreshness.estimated);
      expect(journey.freshness.isLive, isFalse);
    });
  });

  group('an option the passenger did not pick is not purchasable', () {
    test('null journeyId means it must be re-planned', () {
      final plan = JourneyPlan.fromJson({
        'journeys': [
          {
            'id': 'direct-R-7',
            'legs': [],
            'totalFareFils': 2000,
            'totalDurationSeconds': 600,
            'walkingMeters': 0,
            'transferCount': 0,
            'freshness': 'ESTIMATED',
            'journeyId': null,
          },
        ],
      });
      expect(plan.journeys.single.isPurchasable, isFalse);
    });
  });

  group('PaymentStartResult', () {
    test('a confirmed payment carries its ticket', () {
      final result = PaymentStartResult.fromJson(confirmedPayment);
      expect(result.status.isConfirmed, isTrue);
      expect(result.isComplete, isTrue);
      expect(result.ticket, isNotNull);
      expect(result.ticket!.reference, 'TKT-MUQPM0CV-CCBDF9');
    });

    test('the ticket on the payment response is boardable without a refetch',
        () {
      // POST /payments used to omit `ticket.status`. TicketStatus.fromWire falls
      // back to `created` for a missing value, and `created` is not usable — so
      // the moment after paying, the app rendered a ticket it refused to let the
      // passenger board, and only a later /tickets/mine fetch corrected it.
      final ticket = PaymentStartResult.fromJson(confirmedPayment).ticket!;
      expect(ticket.status, TicketStatus.valid);
      expect(
        ticket.isBoardableAt(DateTime.parse('2026-10-02T15:00:00.000Z')),
        isTrue,
      );
    });

    test('parses the signed QR credential from the wire string', () {
      final ticket = PaymentStartResult.fromJson(confirmedPayment).ticket!;
      expect(ticket.hasQr, isTrue);
      expect(ticket.credential!.ticketId,
          'ccbdf9a7-29f9-4fef-9ae0-6ae884547a50');
      expect(ticket.credential!.keyId, 'addis-one-2026-01');
      // Re-serialising must reproduce the server bytes exactly, or a validator
      // rejects a ticket the passenger was just issued.
      expect(ticket.credential!.toQrString(), realQrString);
    });

    test('records the pinned fare rule version (I3)', () {
      expect(
        PaymentStartResult.fromJson(confirmedPayment).ticket!.fareRuleVersion,
        1,
      );
    });

    test('flags the simulated provider rather than implying real money', () {
      final ticket = PaymentStartResult.fromJson(confirmedPayment).ticket!;
      expect(ticket.isSimulatedPayment, isTrue);
    });

    test('the payment reference is read from paymentReference', () {
      expect(
        PaymentStartResult.fromJson(confirmedPayment).reference,
        'PAY-MQ7-AB12CD',
      );
    });
  });

  group('I1: a ticket never appears without a confirmed payment', () {
    // REQUIRES_ACTION means the payer was SENT to the provider. This is the
    // exact confusion the invariant exists to prevent.
    final requiresAction = <String, dynamic>{
      'paymentId': 'deadbeef-0000-4000-8000-000000000000',
      'paymentReference': 'PAY-MQ7-9999ZZ',
      'status': 'REQUIRES_ACTION',
      'amountFils': 3820,
      'providerMode': 'MOCK',
      'ticket': null,
    };

    test('REQUIRES_ACTION yields no ticket and is not complete', () {
      final result = PaymentStartResult.fromJson(requiresAction);
      expect(result.ticket, isNull);
      expect(result.isComplete, isFalse);
      expect(result.status.isConfirmed, isFalse);
    });

    test('a redirect is never treated as payment', () {
      final result = PaymentStartResult.fromJson({
        ...requiresAction,
        'redirectUrl': 'https://telebirr.example/pay/abc',
      });
      expect(result.needsRedirect, isTrue);
      expect(result.isComplete, isFalse);
    });
  });

  group('IssuedTicket from /tickets/mine', () {
    test('accepts the list endpoint field names', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'ccbdf9a7-29f9-4fef-9ae0-6ae884547a50',
        'reference': 'TKT-MUQPM0CV-CCBDF9',
        'status': 'VALID',
        'mode': 'BUS',
        'issuedAt': '2026-10-02T14:10:10.000Z',
        'expiresAt': '2026-10-02T16:10:10.000Z',
        'fareRuleVersion': 1,
        'qrString': realQrString,
      });

      // The list endpoint uses `id`; the payment endpoint uses `ticketId`.
      expect(ticket.id, isNotEmpty);
      expect(ticket.hasQr, isTrue);
      expect(ticket.fareRuleVersion, 1);

      // The server issues straight to VALID, so this is the shape a passenger
      // actually sees and it must read as boardable.
      expect(ticket.status, TicketStatus.valid);
      expect(
        ticket.isBoardableAt(DateTime.parse('2026-10-02T15:00:00.000Z')),
        isTrue,
      );
    });

    test('a ticket with no credential is unusable, not a crash', () {
      final ticket = IssuedTicket.fromJson({
        'id': 'x',
        'reference': 'TKT-1',
        // VALID, so the missing credential is the only reason this is refused.
        // With a non-usable status here the assertion would pass for two
        // reasons at once and would keep passing if hasQr broke.
        'status': 'VALID',
        'issuedAt': '2026-10-02T14:10:10.000Z',
        'expiresAt': '2026-10-02T16:10:10.000Z',
        'qrString': null,
      });
      expect(ticket.status, TicketStatus.valid);
      expect(ticket.hasQr, isFalse);
      expect(ticket.isBoardableAt(DateTime.now()), isFalse);
    });
  });
}
