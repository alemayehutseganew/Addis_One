import 'dart:math';

import 'package:addis_one/core/models/journey.dart';
import 'package:addis_one/core/models/journey_plan.dart';
import 'package:addis_one/core/models/qr_credential.dart';
import 'package:addis_one/core/models/ticket.dart';
import 'package:addis_one/core/money.dart';
import 'package:addis_one/features/passenger/journey_planner/domain/purchase_controller.dart';
import 'package:addis_one/features/passenger/journey_planner/domain/purchase_state.dart';
import 'package:addis_one/features/passenger/journey_planner/domain/transport_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable fake. Each call records what was asked and returns what the test
/// tells it to, so a flow can be driven through states the real provider would
/// produce — including the ones that must NOT yield a ticket.
class FakeTransportRepository implements TransportRepository {
  FakeTransportRepository({
    this.initiateStatus = PaymentStatus.confirmed,
    this.settleAfter = 0,
    this.issueAfter = 0,
    this.ticketWhenIssued,
    this.failWith,
  });

  /// Status the provider reports when the payment is started.
  PaymentStatus initiateStatus;

  /// How many status polls return non-terminal before settling.
  int settleAfter;

  /// How many ticket polls return null before the ticket appears.
  int issueAfter;

  IssuedTicket? ticketWhenIssued;
  ApiException? failWith;

  final List<String> idempotencyKeysUsed = [];
  final List<int> statusPolls = [];
  final List<int> ticketPolls = [];
  int _settleCount = 0;
  int _issueCount = 0;

  @override
  Future<List<Place>> searchPlaces(String query) async => const [];

  @override
  Future<JourneyPlan> planJourney(JourneyPlanRequest request) async =>
      const JourneyPlan(journeys: []);

  @override
  Future<PaymentStartResult> startPayment({
    required Money amount,
    required PaymentMethod method,
    required String idempotencyKey,
    String? journeyId,
  }) async {
    idempotencyKeysUsed.add(idempotencyKey);
    if (failWith != null) throw failWith!;
    return PaymentStartResult(
      paymentId: 'pay-1',
      reference: 'PAY-1',
      status: initiateStatus,
      redirectUrl: initiateStatus == PaymentStatus.requiresAction
          ? 'https://telebirr.example/pay'
          : null,
    );
  }

  @override
  Future<PaymentStatus> paymentStatus(String paymentId) async {
    statusPolls.add(statusPolls.length);
    if (initiateStatus == PaymentStatus.requiresAction) {
      // Stays pending a while, then confirms — like a real redirect flow.
      if (_settleCount++ < settleAfter) return PaymentStatus.pending;
      return PaymentStatus.confirmed;
    }
    return initiateStatus;
  }

  @override
  Future<IssuedTicket?> ticketForPayment(String paymentId) async {
    ticketPolls.add(ticketPolls.length);
    if (_issueCount++ < issueAfter) return null;
    return ticketWhenIssued;
  }

  @override
  Future<List<IssuedTicket>> myTickets() async => const [];

  @override
  Future<TripsResult> myTrips() async =>
      const TripsResult(trips: [], signedIn: true);

  @override
  Future<List<NearbyStop>> nearbyStops(GeoPoint point) async =>
      throw UnimplementedError('location is not exercised by purchase tests');
}

IssuedTicket buildTicket({
  TicketStatus status = TicketStatus.valid,
  bool withQr = true,
  Duration validFor = const Duration(hours: 1),
}) {
  final now = DateTime(2026, 10, 1, 12);
  return IssuedTicket(
    id: 'tkt-1',
    reference: 'TKT-1',
    status: status,
    issuedAt: now,
    expiresAt: now.add(validFor),
    fare: const Money(2500),
    credential: withQr
        ? QrCredential(
            ticketId: 'tkt-1',
            credentialId: 'crd-1',
            issuedAt: now.millisecondsSinceEpoch ~/ 1000,
            expiresAt: now.add(validFor).millisecondsSinceEpoch ~/ 1000,
            nonce: 'abc',
            keyId: 'k1',
            signature: 'sig==',
          )
        : null,
  );
}

/// Deterministic RNG so idempotency key assertions are stable.
Random seededRandom() => Random(42);

void main() {
  group('PurchaseController — happy path', () {
    test('reaches PurchaseSuccess when payment confirms and ticket issues',
        () async {
      final repo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseSuccess>());
      expect((result as PurchaseSuccess).ticket.reference, 'TKT-1');
    });

    test('carries the fare as integer fils, never a float', () {
      // No float conversion anywhere in the money path.
      expect(const Money(2500).fils, 2500);
      expect(const Money(2500).plain, '25.00');
    });
  });

  group('PurchaseController — I1 (no ticket without confirmed payment)', () {
    test('REQUIRES_ACTION alone never yields a ticket', () async {
      // Provider keeps the payment pending forever: the flow must time out into
      // a failure, NOT hand the passenger a ticket.
      final repo = FakeTransportRepository(
        initiateStatus: PaymentStatus.requiresAction,
        settleAfter: 999,
        ticketWhenIssued: buildTicket(),
      );
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        maxPollAttempts: 3,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseFailure>());
      expect(result, isNot(isA<PurchaseSuccess>()));
      // The ticket was never even asked for.
      expect(repo.ticketPolls, isEmpty);
    });

    test('a DECLINED payment yields a failure, never a ticket', () async {
      final repo = FakeTransportRepository(
        initiateStatus: PaymentStatus.failed,
        ticketWhenIssued: buildTicket(),
      );
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseFailure>());
      expect(repo.ticketPolls, isEmpty);
    });

    test('REVERSED after confirmation yields a failure', () async {
      final repo = FakeTransportRepository(
        initiateStatus: PaymentStatus.reversed,
        ticketWhenIssued: buildTicket(),
      );
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseFailure>());
    });

    test('confirmed payment with no issued ticket times out, not succeeds',
        () async {
      final repo = FakeTransportRepository(
        initiateStatus: PaymentStatus.confirmed,
        issueAfter: 999, // never issues
      );
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        maxPollAttempts: 3,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseFailure>());
      expect(result, isNot(isA<PurchaseSuccess>()));
    });

    test('only PurchaseSuccess carries a ticket', () {
      // The sealed union makes this structurally true: success is the only
      // variant with a ticket field at all.
      const failure = PurchaseFailure(ApiFailure.timeout);
      expect(failure, isNot(isA<PurchaseSuccess>()));
      expect(failure.isBusy, isFalse);
    });
  });

  group('PurchaseController — I2 (idempotency)', () {
    test('generates a key before the first attempt', () async {
      final repo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);

      expect(repo.idempotencyKeysUsed, hasLength(1));
      expect(repo.idempotencyKeysUsed.first, isNotEmpty);
    });

    test('reuses the same key when retrying the same purchase', () async {
      final repo = FakeTransportRepository(initiateStatus: PaymentStatus.failed);
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);
      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);

      // Same key twice — the server deduplicates, so the passenger is charged
      // once, not twice.
      expect(repo.idempotencyKeysUsed, hasLength(2));
      expect(repo.idempotencyKeysUsed[0], repo.idempotencyKeysUsed[1]);
    });

    test('issues a fresh key after reset', () async {
      final repo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);
      c.reset();
      await c.purchase(amount: const Money(1500), method: PaymentMethod.telebirr);

      // A genuinely new purchase must not reuse the old key, or it would be
      // silently deduplicated into the previous payment.
      expect(repo.idempotencyKeysUsed[0], isNot(repo.idempotencyKeysUsed[1]));
    });

    test('key is 128-bit hex', () async {
      final repo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);

      expect(repo.idempotencyKeysUsed.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('PurchaseController — errors and state', () {
    test('surfaces a repository failure', () async {
      final repo = FakeTransportRepository(
        failWith: const ApiException(ApiFailure.network, message: 'offline'),
      );
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      final result = await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
      );

      expect(result, isA<PurchaseFailure>());
      final failure = result as PurchaseFailure;
      expect(failure.failure, ApiFailure.network);
      expect(failure.message, 'offline');
    });

    test('starts idle and settles back out of busy', () async {
      final repo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c = PurchaseController(
        repository: repo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      expect(c.state, isA<PurchaseIdle>());
      expect(c.isInFlight, isFalse);

      await c.purchase(amount: const Money(2500), method: PaymentMethod.telebirr);

      expect(c.state, isA<PurchaseSuccess>());
      expect(c.isInFlight, isFalse);
    });

    test('redirects only when the provider requires action', () async {
      String? redirectedTo;

      final redirectRepo = FakeTransportRepository(
        initiateStatus: PaymentStatus.requiresAction,
        settleAfter: 1,
        ticketWhenIssued: buildTicket(),
      );
      final c = PurchaseController(
        repository: redirectRepo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );

      await c.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
        onRedirect: (url) async => redirectedTo = url,
      );
      expect(redirectedTo, 'https://telebirr.example/pay');

      // A direct-confirm provider needs no redirect.
      String? notCalled;
      final directRepo = FakeTransportRepository(ticketWhenIssued: buildTicket());
      final c2 = PurchaseController(
        repository: directRepo,
        pollInterval: Duration.zero,
        random: seededRandom(),
      );
      await c2.purchase(
        amount: const Money(2500),
        method: PaymentMethod.telebirr,
        onRedirect: (url) async => notCalled = url,
      );
      expect(notCalled, isNull);
    });
  });
}
