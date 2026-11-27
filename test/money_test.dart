import 'package:flutter_test/flutter_test.dart';
import 'package:bin_thabit/ui/app.dart';

void main() {
  group('parseMoneyMinor', () {
    test('parses decimal amounts without floating point math', () {
      expect(parseMoneyMinor('1,234.50'), 123450);
      expect(parseMoneyMinor('19'), 1900);
      expect(parseMoneyMinor('0.05'), 5);
      expect(parseMoneyMinor('1,234,567.89'), 123456789);
    });

    test('parses Arabic-Indic and Eastern Arabic digits and separators', () {
      expect(parseMoneyMinor('١٢٣٤٫٥٠'), 123450);
      expect(parseMoneyMinor('۱۲۳٫۴۵'), 12345);
      expect(parseMoneyMinor('١٬٢٣٤٫٥٠'), 123450);
    });

    test('rejects malformed grouping, invalid and over-precision amounts', () {
      expect(parseMoneyMinor(''), isNull);
      expect(parseMoneyMinor('-10'), isNull);
      expect(parseMoneyMinor('12.345'), isNull);
      expect(parseMoneyMinor('1,2,3'), isNull);
      expect(parseMoneyMinor('12,34'), isNull);
      expect(parseMoneyMinor('1..2'), isNull);
      expect(parseMoneyMinor('999999999999999999999999999999'), isNull);
    });
  });

  group('formatMoney', () {
    test('formats large amounts using integer arithmetic', () {
      expect(formatMoney(123450, 'SAR'), '1,234.50 ر.س');
      expect(formatMoney(999999999999999999, 'YER'), '9,999,999,999,999,999.99 ر.ي');
      expect(formatMoney(-5, 'SAR'), '−0.05 ر.س');
    });
  });
}
