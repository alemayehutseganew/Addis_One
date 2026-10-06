import 'package:addis_one/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

/// Money is the boundary type most likely to cause silent revenue bugs, so it
/// is tested harder than anything else in the app.
void main() {
  group('Money construction', () {
    test('stores integer fils only', () {
      final m = Money(2500);
      expect(m.fils, 2500);
      expect(m.plain, '25.00');
      expect(m.currency, 'ETB');
    });

    test('zero is zero', () {
      expect(Money.zero.isZero, isTrue);
      expect(Money.zero.fils, 0);
    });

    test('parses decimal strings exactly', () {
      expect(Money.parse('25.00').fils, 2500);
      expect(Money.parse('25').fils, 2500);
      expect(Money.parse('25.5').fils, 2550);
      expect(Money.parse('0.01').fils, 1);
      expect(Money.parse('12.34').fils, 1234);
    });

    test('parses without float drift', () {
      // 0.1 + 0.2 != 0.3 in IEEE-754. Parsing digit-wise avoids the problem.
      expect(Money.parse('0.10').fils, 10);
      expect(Money.parse('0.20').fils, 20);
      expect(Money.parse('0.30').fils, 30);
      expect(Money.parse('8.20').fils + Money.parse('1.10').fils,
          Money.parse('9.30').fils);
    });

    test('handles negatives', () {
      expect(Money.parse('-25.00').fils, -2500);
      expect(Money.parse('-25.00').isNegative, isTrue);
    });

    test('tolerates currency symbols and spaces', () {
      expect(Money.parse('ETB 25.00').fils, 2500);
      expect(Money.parse(' 25.00 ETB ').fils, 2500);
    });

    test('rejects sub-fil precision', () {
      // Sub-fil amounts cannot be stored; silently truncating would lose money.
      expect(() => Money.parse('25.005'), throwsFormatException);
      expect(() => Money.parse('25.0001'), throwsFormatException);
    });

    test('rejects nonsense', () {
      expect(() => Money.parse(''), throwsFormatException);
      expect(() => Money.parse('abc'), throwsA(anything));
    });

    test('rejects empty currency', () {
      expect(() => Money.validated(100, currency: ''), throwsArgumentError);
    });
  });

  group('arithmetic', () {
    test('adds and subtracts exactly', () {
      expect((Money(1500) + Money(2500)).fils, 4000);
      expect((Money(4000) - Money(1500)).fils, 2500);
    });

    test('sums many fares without drift', () {
      var total = Money.zero;
      for (var i = 0; i < 1000; i++) {
        total = total + Money(10); // 0.10 ETB
      }
      expect(total.fils, 10000);
      expect(total.plain, '100.00');
    });

    test('percentages round half-up and stay integral', () {
      expect(Money(4000).percentageOf(50).fils, 2000);
      expect(Money(4000).percentageOf(100).fils, 4000);
      expect(Money(4000).percentageOf(0).fils, 0);
      // 10 fils * 50% = 5 fils
      expect(Money(10).percentageOf(50).fils, 5);
      // Always an integer, never a fraction of a fil
      expect(Money(333).percentageOf(33).fils, isA<int>());
    });

    test('refuses to mix currencies', () {
      expect(
        () => Money(100) + Money(100, currency: 'USD'),
        throwsArgumentError,
      );
    });

    test('equality is by value', () {
      expect(Money(2500), Money(2500));
      expect(Money(2500), isNot(Money(2501)));
      expect(Money(2500), isNot(Money(2500, currency: 'USD')));
    });
  });

  group('display', () {
    test('plain format always shows two decimals', () {
      expect(Money(5).plain, '0.05');
      expect(Money(2500).plain, '25.00');
      expect(Money(0).plain, '0.00');
    });

    test('display appends the currency code', () {
      expect(Money(2500).display, '25.00 ETB');
    });

    test('locale display does not throw', () {
      expect(Money(2500).displayFor('en'), contains('25'));
      expect(Money(2500).displayFor('am'), isNotEmpty);
    });

    test('majorUnits is available for charting', () {
      expect(Money(2500).majorUnits, 25.0);
    });
  });
}
