// Tests for the vehicle-code boarding flow (steps 1–16).
//
// The properties pinned here are the ones that would cost money if they broke:
//
//  1. Step 3's NO branch is TERMINAL. An unknown code must never fall through
//     into the payment section, and must never be reported as a network error —
//     the two need different messages and the first needs the flow to stop.
//  2. I1: a ticket appears only after the backend CONFIRMS the payment. A
//     provider that sits in REQUIRES_ACTION forever, or a payment that never
//     settles, must produce a FAILURE and must not call the ticket endpoint
//     into existence.
//  3. I2: a retry after a failed payment reuses the SAME idempotency key, so a
//     second attempt converges on one charge rather than two.
//
// A fake repository rather than a mock framework, matching `purchase_controller_test`:
// the point is which calls the controller makes and in what order, and a
// recording fake shows that directly.
import 'dart:math';
import 'dart:ui' as ui;

import 'package:addis_one/core/models/journey.dart';
import 'package:addis_one/core/models/qr_credential.dart';
import 'package:addis_one/core/models/ticket.dart';
import 'package:addis_one/core/models/ticket_validation.dart';
import 'package:addis_one/core/models/vehicle.dart';
import 'package:addis_one/core/money.dart';
import 'package:addis_one/features/passenger/journey_planner/domain/transport_repository.dart';
import 'package:addis_one/features/passenger/vehicle_code/data/sms_gateway.dart';
import 'package:addis_one/features/passenger/vehicle_code/data/ticket_share.dart';
import 'package:addis_one/features/passenger/vehicle_code/domain/vehicle_code_controller.dart';
import 'package:addis_one/features/passenger/vehicle_code/domain/vehicle_code_state.dart';
import 'package:flutter/services.dart';
import 'package:addis_one/features/passenger/vehicle_code/domain/vehicle_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable fake. Every call is recorded so a test can assert not just the
/// final state but which endpoints were touched along the way.
class FakeVehicleRepository implements VehicleRepository {
  FakeVehicleRepository({
    this.vehicle,
    this.lookupFailsWith,
    this.initiateStatus = PaymentStatus.confirmed,
    this.settleAfter = 0,
    this.issueAfter = 0,
    this.ticketsWhenIssued,
    this.startFailsWith,
    this.refreshReturns,
  });

  /// What `lookupVehicle` resolves to. Null models "no such vehicle".
  VehicleProfile? vehicle;
  ApiException? lookupFailsWith;

  PaymentStatus initiateStatus;

  /// Status polls returning non-terminal before settling.
  int settleAfter;

  /// The full batch, when testing a group booking. Falls back to a single
  /// ticket so single-passenger tests stay readable.
  List<IssuedTicket>? ticketsWhenIssued;

  /// Ticket polls returning nothing before the batch appears.
  int issueAfter;
  ApiException? startFailsWith;
  IssuedTicket? refreshReturns;

  final List<String> codesLookedUp = [];
  final List<String> idempotencyKeysUsed = [];
  final List<String> methodsUsed = [];
  final List<String> statusPolls = [];
  final List<String> ticketPolls = [];
  final List<int> quantities = [];
  final List<Money> amounts = [];

  /// Boarding positions handed to the most recent lookup, so a test can assert
  /// the coordinates reached the server and not just that a lookup happened.
  final List<GeoPoint?> boardingPoints = [];

  int _settleCount = 0;
  int _issueCount = 0;

  /// Quantity of the most recent payment, so a fake can be sized like the demo.
  int lastQuantity = 1;

  @override
  Future<VehicleProfile?> lookupVehicle(
    String code, {
    GeoPoint? boardingPoint,
  }) async {
    codesLookedUp.add(code);
    boardingPoints.add(boardingPoint);
    if (lookupFailsWith != null) throw lookupFailsWith!;
    return vehicle;
  }

  @override
  Future<PaymentStartResult> startVehiclePayment({
    required VehicleProfile vehicle,
    required Money amount,
    required int quantity,
    required PaymentMethod method,
    required String idempotencyKey,
  }) async {
    idempotencyKeysUsed.add(idempotencyKey);
    methodsUsed.add(method.wire);
    quantities.add(quantity);
    amounts.add(amount);
    lastQuantity = quantity;
    if (startFailsWith != null) throw startFailsWith!;
    return PaymentStartResult(
      paymentId: 'vp-1',
      reference: 'VP-1',
      status: initiateStatus,
      redirectUrl: initiateStatus == PaymentStatus.requiresAction
          ? 'https://telebirr.example/pay'
          : null,
    );
  }

  @override
  Future<PaymentStatus> vehiclePaymentStatus(String paymentId) async {
    statusPolls.add(paymentId);
    // Stays pending for a while, then confirms — like a real redirect flow.
    if (initiateStatus == PaymentStatus.requiresAction) {
      if (_settleCount++ < settleAfter) return PaymentStatus.pending;
      return PaymentStatus.confirmed;
    }
    return initiateStatus;
  }

  @override
  Future<List<IssuedTicket>> ticketsForVehiclePayment(String paymentId) async {
    ticketPolls.add(paymentId);
    if (_issueCount++ < issueAfter) return const [];
    return ticketsWhenIssued ?? [buildTicket()];
  }

  @override
  Future<IssuedTicket?> refreshTicket(String ticketId) async =>
      refreshReturns;

  /// Scans the fake will hand back, and the verdict a scan will produce.
  List<TicketValidationRecord> ledger = [];
  ValidationOutcome? nextOutcome;

  @override
  Future<List<TicketValidationRecord>> ticketValidations(
    String ticketId,
  ) async =>
      List<TicketValidationRecord>.from(ledger);

  @override
  Future<ValidationOutcome> recordValidation({
    required String ticketId,
    required ValidationKind kind,
    String? tripId,
  }) async {
    final scripted = nextOutcome;
    if (scripted != null) return scripted;

    final record = TicketValidationRecord(
      kind: kind,
      scannedAt: DateTime(2026, 10, 1, 12),
      tripId: tripId,
    );
    ledger.add(record);
    return kind == ValidationKind.entry
        ? EntryAccepted(record: record)
        : ExitAccepted(record: record);
  }
}

/// Deterministic RNG so idempotency key assertions are stable.
Random seededRandom() => Random(42);

VehicleProfile buildVehicle({
  VehicleStatus status = VehicleStatus.active,
  int fareFils = 1500,
  String code = 'AA 12345',
}) {
  return VehicleProfile(
    vehicleId: 'veh-1',
    code: code,
    routeLabel: 'Route 7 — Piazza ⇄ Bole',
    operatorName: 'Blue Nile Transport',
    fare: Money(fareFils),
    status: status,
  );
}

IssuedTicket buildTicket({
  String id = 'tkt-1',
  TicketStatus status = TicketStatus.valid,
  bool withQr = true,
}) {
  final now = DateTime(2026, 10, 1, 12);
  return IssuedTicket(
    id: id,
    reference: id == 'tkt-1' ? 'TKT-1' : id.toUpperCase(),
    status: status,
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    fare: const Money(1500),
    credential: withQr
        ? QrCredential(
            ticketId: id,
            credentialId: 'crd-$id',
            issuedAt: now.millisecondsSinceEpoch ~/ 1000,
            expiresAt:
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
            nonce: 'abc',
            keyId: 'k1',
            signature: 'sig==',
          )
        : null,
  );
}

VehicleCodeController buildController(FakeVehicleRepository repo) {
  return VehicleCodeController(
    repository: repo,
    pollInterval: Duration.zero,
    maxPollAttempts: 3,
    random: seededRandom(),
  );
}
void main() {
  group('Steps 2–3 — lookup', () {
    test('a registered code resolves to VehicleFound with its fare',
        () async {
      final repo = FakeVehicleRepository(vehicle: buildVehicle());
      final c = buildController(repo);

      final state = await c.lookup('AA 12345');

      expect(state, isA<VehicleFound>());
      expect((state as VehicleFound).vehicle.fare, const Money(1500));
      expect(repo.codesLookedUp, ['AA 12345']);
    });

    test('an unknown code yields VehicleNotFound, NOT a failure', () async {
      // The distinction the blueprint's step 3 turns on: "no such vehicle" is a
      // true answer about the world, not an absence of one.
      final repo = FakeVehicleRepository(vehicle: null);
      final c = buildController(repo);

      final state = await c.lookup('ZZ 00000');

      expect(state, isA<VehicleNotFound>());
      expect(state, isNot(isA<VehicleLookupFailure>()));
      expect((state as VehicleNotFound).code, 'ZZ 00000');
    });

    test('a not-found code never reaches the payment section', () async {
      // Terminal: no payment call may be made after a miss.
      final repo = FakeVehicleRepository(vehicle: null);
      final c = buildController(repo);

      await c.lookup('ZZ 00000');

      expect(repo.idempotencyKeysUsed, isEmpty);
      expect(repo.methodsUsed, isEmpty);
    });

    test('a code is normalised to upper case before searching', () async {
      // A code read off a plate arrives lowercase with stray whitespace.
      // Without normalisation the server reports "not found" for a vehicle
      // that plainly exists.
      final repo = FakeVehicleRepository(vehicle: buildVehicle());
      final c = buildController(repo);

      await c.lookup('  aa 12345  ');

      expect(repo.codesLookedUp, ['AA 12345']);
    });

    test('an empty code is a validation failure and is not searched for',
        () async {
      final repo = FakeVehicleRepository(vehicle: buildVehicle());
      final c = buildController(repo);

      final state = await c.lookup('   ');

      expect(state, isA<VehicleLookupFailure>());
      expect((state as VehicleLookupFailure).failure, ApiFailure.validation);
      expect(repo.codesLookedUp, isEmpty);
    });

    test('a network error is a failure, not a not-found', () async {
      // The two must never collapse: one tells the passenger to re-check the
      // code, the other to wait for signal.
      final repo = FakeVehicleRepository(
        lookupFailsWith: const ApiException(ApiFailure.network),
      );
      final c = buildController(repo);

      final state = await c.lookup('AA 12345');

      expect(state, isA<VehicleLookupFailure>());
      expect((state as VehicleLookupFailure).failure, ApiFailure.network);
    });
  });

  group('Steps 4–5 — vehicle availability', () {
    test('a vehicle in maintenance is unavailable, not purchasable', () async {
      // The code is CORRECT. Sending the passenger back to re-check it would be
      // asking them to fix something that is not broken.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(status: VehicleStatus.maintenance),
      );
      final c = buildController(repo);

      final state = await c.lookup('AA 12345');

      expect(state, isA<VehicleUnavailable>());
      expect(state, isNot(isA<VehicleNotFound>()));
    });

    test('a retired vehicle is unavailable', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(status: VehicleStatus.retired),
      );
      final c = buildController(repo);

      expect(await c.lookup('AA 12345'), isA<VehicleUnavailable>());
    });

    test('a zero fare is unavailable — nothing can be reconciled against it',
        () async {
      final repo = FakeVehicleRepository(vehicle: buildVehicle(fareFils: 0));
      final c = buildController(repo);

      expect(await c.lookup('AA 12345'), isA<VehicleUnavailable>());
    });

    test('isPurchasable is false for anything but an active, priced vehicle',
        () {
      expect(buildVehicle().isPurchasable, isTrue);
      expect(
        buildVehicle(status: VehicleStatus.outOfService).isPurchasable,
        isFalse,
      );
      expect(buildVehicle(fareFils: 0).isPurchasable, isFalse);
    });
  });
group('Steps 6–9 — payment', () {
    test('a confirmed payment with an issued ticket reaches VehicleTicketsIssued',
        () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect(state, isA<VehicleTicketsIssued>());
      expect((state as VehicleTicketsIssued).first.id, 'tkt-1');
      expect(state.vehicle.code, 'AA 12345');
      expect(state.tickets, hasLength(1));
    });

    test('a payment stuck in REQUIRES_ACTION FAILS and issues no ticket',
        () async {
      // The exact failure the blueprint warns about: a provider that never
      // settles must time out into a FAILURE, and the ticket endpoint must
      // never be reached.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        initiateStatus: PaymentStatus.requiresAction,
        settleAfter: 99,
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect(state, isA<VehiclePaymentFailed>());
      expect((state as VehiclePaymentFailed).failure, ApiFailure.timeout);
      expect(repo.ticketPolls, isEmpty);
    });

    test('a ticket offered without a confirmed payment is not accepted',
        () async {
      // Guards the shortcut: a repository handing back a ticket must not be
      // enough on its own — the status has to confirm first.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        initiateStatus: PaymentStatus.failed,
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect(state, isA<VehiclePaymentFailed>());
      expect(repo.ticketPolls, isEmpty);
    });

    test('a ticket that is never issued is a timeout failure', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        issueAfter: 99,
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect(state, isA<VehiclePaymentFailed>());
      expect((state as VehiclePaymentFailed).failure, ApiFailure.timeout);
    });

    test('each approved provider reaches the wire', () async {
      for (final method in PaymentMethod.values) {
        final repo = FakeVehicleRepository(
          vehicle: buildVehicle(),
          ticketsWhenIssued: [buildTicket()],
        );
        final c = buildController(repo);

        final state = await c.pay(vehicle: buildVehicle(), method: method);

        expect(state, isA<VehicleTicketsIssued>(), reason: method.wire);
        expect(repo.methodsUsed, [method.wire]);
      }
    });

    test('a redirect is opened but is never treated as payment', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        initiateStatus: PaymentStatus.requiresAction,
        settleAfter: 1,
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      var redirects = 0;
      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        onRedirect: (_) async => redirects++,
      );

      expect(redirects, 1);
      // Still had to poll to CONFIRMED before a ticket could exist.
      expect(repo.statusPolls, isNotEmpty);
      expect(state, isA<VehicleTicketsIssued>());
    });

    test('a start failure surfaces as a retryable payment failure', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        startFailsWith: const ApiException(ApiFailure.network),
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect(state, isA<VehiclePaymentFailed>());
      expect((state as VehiclePaymentFailed).failure, ApiFailure.network);
      // The vehicle is retained so Retry does not need a second lookup.
      expect(state.vehicle, isNotNull);
      expect(state.canRetry, isTrue);
    });

    test('a rejected validation is NOT offered a retry', () async {
      // A declined card fails identically forever. Offering Retry there invites
      // another attempt at a payment that was never going to work.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        startFailsWith: const ApiException(ApiFailure.validation),
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
      );

      expect((state as VehiclePaymentFailed).canRetry, isFalse);
    });
  });
group('I2 — idempotency across retries', () {
    test('a retry after a failed payment reuses the SAME key', () async {
      // The whole point of I2: a retry must converge on one charge, not two.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        startFailsWith: const ApiException(ApiFailure.network),
      );
      final c = buildController(repo);

      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);
      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);

      expect(repo.idempotencyKeysUsed, hasLength(2));
      expect(repo.idempotencyKeysUsed.toSet(), hasLength(1));
    });

    test('reset() issues a NEW key for the next vehicle', () async {
      // Without this, buying a second vehicle would replay the first payment
      // and hand back the first ticket.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);
      c.reset();
      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);

      expect(repo.idempotencyKeysUsed.toSet(), hasLength(2));
    });

    test('a lookup alone does NOT burn an idempotency key', () async {
      // The key is minted at payment time. A passenger who looks a vehicle up
      // and backs out must not have consumed one.
      final repo = FakeVehicleRepository(vehicle: buildVehicle());
      final c = buildController(repo);

      await c.lookup('AA 12345');
      await c.lookup('AA 99999');
      c.lookup('ZZ 00000');

      expect(repo.idempotencyKeysUsed, isEmpty);
    });

    test('the key is 128 bits of hex — 32 characters', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);

      expect(repo.idempotencyKeysUsed, hasLength(1));
      expect(repo.idempotencyKeysUsed.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('Steps 15–16 — validation refresh', () {
    test('a refreshed VALIDATED ticket is returned', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        refreshReturns: buildTicket(status: TicketStatus.validated),
      );
      final c = buildController(repo);

      final fresh = await c.refresh(buildTicket());

      expect(fresh, isNotNull);
      expect(fresh!.status, TicketStatus.validated);
      expect(fresh.status.isTerminal, isFalse);
    });

    test('an unavailable refresh endpoint returns null, not an exception', () async {
      // On a route with no signal the validator may be the only device with a
      // connection. Losing the QR over that would be the worst possible outcome.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        refreshReturns: null,
      );
      final c = buildController(repo);

      expect(await c.refresh(buildTicket()), isNull);
    });
  });

  group('Step 13 — SMS body', () {
    test('carries reference, vehicle code and the credential', () {
      const builder = TicketSmsBuilder();
      final body = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      );

      expect(body, contains('TKT-1'));
      expect(body, contains('AA 12345'));
      expect(body, contains('{"t":"tkt-1"}'));
    });

    test('carries NO fare and NO route (I4)', () {
      // A forwarded or photographed message must not disclose what someone
      // paid or where they were going.
      const builder = TicketSmsBuilder();
      final body = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      )!;

      expect(body, isNot(contains('15.00')));
      expect(body, isNot(contains('Piazza')));
      expect(body, isNot(contains('Bole')));
    });

    test('returns null rather than truncating an oversized credential', () {
      // A half-credential QR scans and then fails at the validator, which
      // looks to the passenger like being falsely rejected on board.
      const builder = TicketSmsBuilder(maxLength: 100);
      final body = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: 'x' * 500,
      );

      expect(body, isNull);
    });
  });

  group('Group booking — paying for friends and family', () {
    test('quantity 4 buys four separate tickets in one payment', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [
          buildTicket(id: 'tkt-1'),
          buildTicket(id: 'tkt-2'),
          buildTicket(id: 'tkt-3'),
          buildTicket(id: 'tkt-4'),
        ],
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 4,
      ) as VehicleTicketsIssued;

      expect(state.tickets, hasLength(4));
      expect(state.quantityPaid, 4);
      // Each is independently signed and independently single-use — that is
      // what makes forwarding each one correct rather than a way to ride free.
      expect(state.tickets.map((t) => t.id).toSet(), hasLength(4));
    });

    test('the amount sent is the fare times the quantity, in exact fils',
        () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      await c.pay(
        vehicle: buildVehicle(fareFils: 1500),
        method: PaymentMethod.telebirr,
        quantity: 3,
      );

      expect(repo.quantities, [3]);
      expect(repo.amounts.single, const Money(4500));
    });

    test('no quantity defaults to a single ticket', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      await c.pay(vehicle: buildVehicle(), method: PaymentMethod.telebirr);

      expect(repo.quantities, [1]);
      expect(repo.amounts.single, const Money(1500));
    });

    test('a quantity of zero is coerced to one, never to an empty purchase',
        () async {
      // Zero would create a payment for nothing and produce a state carrying
      // no ticket, which is not a successful purchase.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket()],
      );
      final c = buildController(repo);

      await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 0,
      );

      expect(repo.quantities, [1]);
    });

    test('a short issuance is flagged rather than reported as success',
        () async {
      // Paid for four, issued three. The passenger has a dispute and must hear
      // about it here, not discover it at the validator.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [
          buildTicket(id: 'tkt-1'),
          buildTicket(id: 'tkt-2'),
          buildTicket(id: 'tkt-3'),
        ],
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 4,
      ) as VehicleTicketsIssued;

      expect(state.isShortIssued, isTrue);
      expect(state.shortfall, 1);
    });

    test('a complete issuance is not flagged', () async {
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        ticketsWhenIssued: [buildTicket(id: 'a'), buildTicket(id: 'b')],
      );
      final c = buildController(repo);

      final state = await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 2,
      ) as VehicleTicketsIssued;

      expect(state.isShortIssued, isFalse);
    });

    test('one idempotency key covers the whole group', () async {
      // A retry must replay the entire purchase, never issue a second batch of
      // tickets for a payment already made.
      final repo = FakeVehicleRepository(
        vehicle: buildVehicle(),
        startFailsWith: const ApiException(ApiFailure.network),
      );
      final c = buildController(repo);

      await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 4,
      );
      await c.pay(
        vehicle: buildVehicle(),
        method: PaymentMethod.telebirr,
        quantity: 4,
      );

      expect(repo.idempotencyKeysUsed.toSet(), hasLength(1));
      expect(repo.quantities, [4, 4]);
    });

    test('no ticket carries any passenger name — the QR is the whole ticket',
        () async {
      // I4: the credential carries identifiers only. That is precisely why
      // anonymous forwarding is safe — nothing in the system records who is
      // travelling, so nothing about them can leak when it is shared.
      final ticket = buildTicket();

      expect(ticket.credential!.toQrString(), isNot(contains('name')));
      expect(ticket.credential!.toQrString(), isNot(contains('passenger')));
    });
  });

  group('Money scaling for groups', () {
    test('multiplies by an integer count exactly', () {
      expect(const Money(1500) * 3, const Money(4500));
      expect(const Money(1500) * 1, const Money(1500));
      expect(const Money(999) * 7, const Money(6993));
    });

    test('times() is the same operation, named', () {
      expect(const Money(250).times(4), const Money(1000));
    });

    test('keeps the currency', () {
      expect((const Money(100) * 2).currency, 'ETB');
    });
  });

  group('Sharing a ticket', () {
    const builder = TicketShareBuilder();

    test('carries reference, vehicle code and the credential', () {
      final message = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1","s":"sig"}',
      );

      expect(message, contains('TKT-1'));
      expect(message, contains('AA 12345'));
      expect(message, contains('{"t":"tkt-1","s":"sig"}'));
    });

    test('carries NO fare (I4)', () {
      // A forwarded ticket ends up in group chats that get screenshotted.
      // It must not disclose what the payer paid.
      final message = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      );

      expect(message, isNot(contains('15.00')));
      expect(message, isNot(contains('1500')));
      expect(message.toLowerCase(), isNot(contains('fare')));
    });

    test('states that one ticket is one boarding', () {
      // Always said, for every ticket. The message lands in a group chat where
      // it may be forwarded onward by someone who never read it, so the
      // constraint has to travel with the code.
      final message = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      );

      expect(message, contains('One ticket = one boarding'));
      expect(message, contains('does not create another ticket'));
    });

    test('says the same thing when one of several tickets is shared', () {
      // Not softened or omitted for an individual ticket in a group: that one
      // is the one most likely to be re-forwarded.
      final message = builder.build(
        ticketReference: 'TKT-2',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-2"}',
        ticketNumber: 2,
        totalTickets: 4,
      );

      expect(message, contains('One ticket = one boarding'));
    });

    test('numbers the ticket within a group booking', () {
      // Tells the recipient which of several forwarded tickets is theirs,
      // without ever saying whose it is.
      final message = builder.build(
        ticketReference: 'TKT-3',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-3"}',
        ticketNumber: 3,
        totalTickets: 4,
      );

      expect(message, contains('Ticket 3 of 4'));
    });

    test('omits the position for a single-ticket booking', () {
      final message = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      );

      expect(message, isNot(contains('Ticket 1 of 1')));
    });

    test('includes the route only when one is supplied', () {
      // The route lets the recipient confirm they are boarding the right
      // vehicle, and unlike the fare it says nothing about the payer.
      final withRoute = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
        vehicleRoute: 'Route 7',
      );
      final withoutRoute = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
      );

      expect(withRoute, contains('Route 7'));
      expect(withoutRoute, isNot(contains('Route:')));
    });

    test('an empty route label is omitted rather than rendered blank', () {
      final message = builder.build(
        ticketReference: 'TKT-1',
        vehicleCode: 'AA 12345',
        qrString: '{"t":"tkt-1"}',
        vehicleRoute: '   ',
      );

      expect(message, isNot(contains('Route:')));
    });

    test('ShareTarget round-trips over the wire', () {
      for (final target in ShareTarget.values) {
        expect(ShareTarget.fromWire(target.wire), target);
      }
      // Anything unrecognised degrades to the system sheet rather than throwing
      // on a passenger mid-boarding.
      expect(ShareTarget.fromWire('telegram'), ShareTarget.system);
      expect(ShareTarget.fromWire(null), ShareTarget.system);
    });

    test('shareQr passes PNG bytes, file name and text over the channel', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('addis_one_passenger/share');
      String? method;
      Map<String, dynamic>? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        method = call.method;
        args = Map<String, dynamic>.from(call.arguments as Map);
        return true;
      });
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));

      const service = MethodChannelTicketShareService();
      final png = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final shared = await service.shareQr(
        pngBytes: png,
        fileName: 'addis-one-ticket-TKT-1.png',
        text: 'ticket text',
        target: ShareTarget.whatsapp,
      );

      expect(shared, isTrue);
      expect(method, 'shareQr');
      expect(args!['fileName'], 'addis-one-ticket-TKT-1.png');
      expect(args!['text'], 'ticket text');
      expect(args!['target'], 'whatsapp');
      expect(List<int>.from(args!['pngBytes'] as List), List<int>.from(png));
    });

    test('shareQr rejects empty PNG, file name and text', () async {
      const service = MethodChannelTicketShareService();
      expect(
        () => service.shareQr(
          pngBytes: Uint8List(0),
          fileName: 'a.png',
          text: 't',
        ),
        throwsArgumentError,
      );
      expect(
        () => service.shareQr(
          pngBytes: Uint8List.fromList([1]),
          fileName: '  ',
          text: 't',
        ),
        throwsArgumentError,
      );
      expect(
        () => service.shareQr(
          pngBytes: Uint8List.fromList([1]),
          fileName: 'a.png',
          text: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('ticketQrFileName carries the reference and nothing else', () {
      expect(ticketQrFileName('TKT-123'), 'addis-one-ticket-TKT-123.png');
      // Sanitised: the name crosses into the OS share sheet and must not
      // carry path separators or anything a chat app might execute.
      expect(ticketQrFileName('../TKT 1/x'), 'addis-one-ticket-___TKT_1_x.png');
    });
  });

  group('Sharing a ticket QR image', () {
    test('renders a non-empty PNG', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final png = await renderTicketQrPng(qrString: '{"t":"tkt-1"}');

      expect(png, isNotNull);
      expect(png!.lengthInBytes, greaterThan(100));
      // PNG magic: 89 50 4E 47 0D 0A 1A 0A — the share sheet sniffs the
      // content type from the bytes, so a corrupt header means the image
      // arrives unsendable even when the file extension says .png.
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    });

    test('an empty payload renders nothing rather than an unscannable code',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await renderTicketQrPng(qrString: '   '), isNull);
    });

    test('renders a white-framed square at the requested resolution', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const qrString = '{"t":"tkt-1"}';
      final png = await renderTicketQrPng(
        qrString: qrString,
        qrPixelSize: 512,
        quietModules: 4,
      );

      expect(png, isNotNull);
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        expect(image.width, image.height);
        expect(image.width, greaterThan(512));
      } finally {
        image.dispose();
      }
    });
  });
}