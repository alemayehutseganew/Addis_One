// Regression tests for the typed models behind the duty screens.
//
// Each of these replaced a `row['key'] as String` lookup. The failure they all
// guard against is the same one, and it is silent: an untyped read of a field
// the server did not send produces a blank cell rather than an error, so a
// renamed column or a changed response shape looks exactly like "you have no
// data". The models make the absent case explicit and testable.
import 'package:addis_one/core/models/reference.dart';
import 'package:addis_one/core/models/trip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Trip', () {
    Map<String, dynamic> tripJson({
      String status = 'SCHEDULED',
      List<String> transitions = const ['BOARDING', 'DELAYED'],
    }) =>
        {
          'id': 'trip_1',
          'status': status,
          'availableTransitions': transitions,
          'routeName': 'Piazza - Kirkos',
          'routeCode': 'R-3',
          'direction': 'OUTBOUND',
          'vehiclePlate': 'AB-123-C',
          'scheduledDeparture': '2026-10-04T06:30:00.000Z',
        };

    test('offers Start when the server says departing is permitted', () {
      // The regression this model exists for. The previous screen kept its own
      // copy of the status set and omitted BOARDING and DELAYED from it, so a
      // driver whose trip had gone DELAYED - which the server permits starting -
      // was shown no controls at all.
      final t = Trip.fromJson(tripJson(transitions: const ['BOARDING']));
      expect(t.canStart, isTrue);
      expect(t.canComplete, isFalse);
    });

    test('offers Start from BOARDING too, which is a real state', () {
      final t = Trip.fromJson(
        tripJson(status: 'BOARDING', transitions: const ['IN_PROGRESS']),
      );
      expect(t.canStart, isTrue);
    });

    test('offers Complete only when COMPLETED is reachable', () {
      expect(
        Trip.fromJson(tripJson(transitions: const ['COMPLETED'])).canComplete,
        isTrue,
      );
      expect(
        Trip.fromJson(tripJson(transitions: const ['BOARDING'])).canComplete,
        isFalse,
      );
    });

    test('a finished trip offers nothing', () {
      final t = Trip.fromJson(
        tripJson(status: 'COMPLETED', transitions: const []),
      );
      expect(t.canStart, isFalse);
      expect(t.canComplete, isFalse);
      expect(t.isFinished, isTrue);
    });

    test('an absent transitions list permits nothing', () {
      // Permissive by default would offer buttons on a trip that is already
      // finished, and the resulting refusal would look like an app fault.
      final t = Trip.fromJson({'id': 'trip_1', 'status': 'COMPLETED'});
      expect(t.canStart, isFalse);
      expect(t.canComplete, isFalse);
      expect(t.availableTransitions, isEmpty);
    });

    test('a trip with no id is not actionable', () {
      expect(Trip.fromJson(tripJson()).isActionable, isTrue);
      expect(Trip.fromJson({'status': 'SCHEDULED'}).isActionable, isFalse);
    });

    test('a malformed date reads as absent, not as 1970', () {
      expect(Trip.fromJson(tripJson()).scheduledDeparture, isNotNull);
      final bad = Trip.fromJson({
        ...tripJson(),
        'scheduledDeparture': 'not-a-date',
      });
      expect(bad.scheduledDeparture, isNull);
    });

    test('a non-string transition entry is dropped', () {
      final t = Trip.fromJson({
        ...tripJson(),
        'availableTransitions': ['BOARDING', 42, null],
      });
      expect(t.availableTransitions, {'BOARDING'});
    });

    test('a TripManifest reads the server counts, not a recount', () {
      final m = TripManifest.fromJson(const {
        'tripId': 'trip_1',
        'status': 'IN_PROGRESS',
        'ticketCount': 40,
        'validatedCount': 12,
        'tickets': [
          {
            'reference': 'TKT-1',
            'status': 'VALIDATED',
            'passengerName': 'Abebe',
            'mode': 'BUS',
          },
        ],
      });
      expect(m.ticketCount, 40);
      expect(m.outstanding, 28);
      expect(m.tickets.single.passengerName, 'Abebe');
    });

    test('outstanding never goes negative on inconsistent counts', () {
      final m = TripManifest.fromJson(const {
        'tripId': 't',
        'status': 'COMPLETED',
        'ticketCount': 3,
        'validatedCount': 9,
      });
      expect(m.outstanding, 0);
    });

    test('absent manifest counts read as zero rather than throwing', () {
      final m = TripManifest.fromJson(const {'tripId': 't'});
      expect(m.ticketCount, 0);
      expect(m.tickets, isEmpty);
    });
  });

  group('reference models', () {
    test('a Stop reads the fields the server sends', () {
      final s = Stop.fromJson(const {
        'id': 's1',
        'code': 'PIA-01',
        'name': 'Piazza',
        'nameAm': 'Piazza-',
        'latitude': 9.03,
        'longitude': 38.74,
        'zone': 'Z1',
        'hasShelter': true,
        'isActive': true,
      });
      expect(s.name, 'Piazza');
      expect(s.zone, 'Z1');
      expect(s.hasShelter, isTrue);
      expect(s.isActive, isTrue);
    });

    test('an absent isActive reads as active, not withdrawn', () {
      // The dangerous direction: these lists only include withdrawn records when
      // asked, so defaulting to inactive would show every working stop as shut.
      expect(Stop.fromJson(const {'id': 's1', 'name': 'Piazza'}).isActive, isTrue);
    });

    test('a Route reports distance in metres or kilometres', () {
      expect(
        Route.fromJson(const {'id': 'r', 'distanceMeters': 4200}).distanceLabel,
        '4.2 km',
      );
      expect(
        Route.fromJson(const {'id': 'r', 'distanceMeters': 800}).distanceLabel,
        '800 m',
      );
      expect(Route.fromJson(const {'id': 'r'}).distanceLabel, isNull);
    });

    test('a Vehicle labels itself from what it has', () {
      expect(
        Vehicle.fromJson(const {
          'id': 'v',
          'plateNumber': 'AB-123-C',
          'make': 'Volvo',
          'model': 'B7R',
          'mode': 'BUS',
        }).label,
        'AB-123-C · Volvo B7R · BUS',
      );
      expect(
        Vehicle.fromJson(const {'id': 'v', 'plateNumber': 'AA-1'}).label,
        'AA-1',
      );
    });

    test('a FareRule separates live from draft by status, not by version', () {
      // Highest version is not the live one after a rollback, and activating the
      // wrong version is a revenue event.
      final rolledBack = FareRule.fromJson(const {
        'id': 'f1',
        'ruleKey': 'Z1_Z2',
        'version': 9,
        'status': 'SUPERSEDED',
      });
      expect(rolledBack.isLive, isFalse);
      expect(rolledBack.isDraft, isFalse);

      final draft = FareRule.fromJson(const {
        'id': 'f2',
        'ruleKey': 'Z1_Z2',
        'version': 10,
        'status': 'DRAFT',
      });
      expect(draft.isDraft, isTrue);
      expect(draft.isLive, isFalse);
    });

    test('a FareRule reports zones as any when only one side is set', () {
      expect(
        FareRule.fromJson(const {'id': 'f', 'originZone': 'Z1'}).zonesLabel,
        'Z1 → any',
      );
      expect(FareRule.fromJson(const {'id': 'f'}).zonesLabel, isNull);
    });

    test('a StaffMember falls back through the identifiers it has', () {
      expect(
        StaffMember.fromJson(const {
          'id': 'st1',
          'role': 'INSPECTOR',
          'displayName': 'Selassie I Inspector',
        }).label,
        'Selassie I Inspector',
      );
      expect(
        StaffMember.fromJson(const {
          'id': 'st1',
          'role': 'DRIVER',
          'employeeCode': 'TB-007',
        }).label,
        'TB-007',
      );
    });

    test('a StaffMember is working only while active and un-terminated', () {
      expect(
        StaffMember.fromJson(const {'id': 's', 'role': 'DRIVER'}).isWorking,
        isTrue,
      );
      expect(
        StaffMember.fromJson(const {
          'id': 's',
          'role': 'DRIVER',
          'terminatedAt': '2026-10-01T00:00:00.000Z',
        }).isWorking,
        isFalse,
      );
    });

    test('a StaffDevice reads isEnrolled, not a timestamp', () {
      // Reading `enrolledAt` would leave every device looking unenrolled and
      // offer to enrol one that is already enrolled.
      expect(
        StaffDevice.fromJson(const {
          'id': 'd',
          'deviceId': 'dev1',
          'isEnrolled': true,
        }).isEnrolled,
        isTrue,
      );
      expect(
        StaffDevice.fromJson(const {'id': 'd', 'deviceId': 'dev1'}).isEnrolled,
        isFalse,
      );
    });

    test('a CashVariance distinguishes short, over and balanced', () {
      expect(
        CashVariance.fromJson(const {'id': 'c', 'varianceFils': -1000}).isShort,
        isTrue,
      );
      expect(
        CashVariance.fromJson(const {'id': 'c', 'varianceFils': 1000}).isShort,
        isFalse,
      );
      expect(
        CashVariance.fromJson(const {'id': 'c', 'varianceFils': 0}).isBalanced,
        isTrue,
      );
      expect(CashVariance.fromJson(const {'id': 'c'}).isBalanced, isFalse);
    });

    test('a Complaint reads open and settled states', () {
      expect(
        Complaint.fromJson(const {'reference': 'CMP-1', 'status': 'OPEN'}).isOpen,
        isTrue,
      );
      expect(
        Complaint.fromJson(const {'reference': 'CMP-1', 'status': 'RESOLVED'})
            .isSettled,
        isTrue,
      );
    });
  });

  group('Json helpers', () {
    test('birr keeps absent distinct from zero', () {
      // "no per-km component" and "charges zero per km" are different claims, and
      // rendering both as 0.00 would assert the second.
      expect(Json.birr(null), isNull);
      expect(Json.birr(1500), '15.00');
      expect(Json.birr(0), '0.00');
      expect(Json.birr('nope'), isNull);
    });

    test('optStr collapses blank and null to absent', () {
      expect(Json.optStr(null), isNull);
      expect(Json.optStr('  '), isNull);
      expect(Json.optStr('null'), isNull);
      expect(Json.optStr('Z1'), 'Z1');
    });

    test('str never yields the text null', () {
      expect(Json.str(null), '');
      expect(Json.str(0), '0');
    });
  });
}