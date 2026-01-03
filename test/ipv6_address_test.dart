import 'dart:io';
import 'package:test/test.dart';

void main() {
  group('InternetAddress IPv6 Tests', () {
    test('Parse IPv4 address', () {
      final addr = InternetAddress('152.42.240.103');
      expect(addr.address, equals('152.42.240.103'));
      expect(addr.type, equals(InternetAddressType.IPv4));
    });

    test('Parse IPv6 loopback', () {
      final addr = InternetAddress('::1');
      expect(addr.address, equals('::1'));
      expect(addr.type, equals(InternetAddressType.IPv6));
    });

    test('Parse full IPv6 address with abbreviated segments', () {
      final addr = InternetAddress('2400:6180:0:d2:0:2:8351:9000');
      print('Parsed address: ${addr.address}');
      print('Type: ${addr.type}');
      expect(addr.type, equals(InternetAddressType.IPv6));
    });

    test('Parse IPv6 all zeros', () {
      final addr = InternetAddress('::');
      expect(addr.address, equals('::'));
      expect(addr.type, equals(InternetAddressType.IPv6));
    });

    test('Parse IPv6 with leading zeros', () {
      final addr = InternetAddress('2001:0db8:0000:0000:0000:0000:0000:0001');
      print('Parsed address: ${addr.address}');
      expect(addr.type, equals(InternetAddressType.IPv6));
    });

    test('Try parse with tryParse', () {
      final addr1 = InternetAddress.tryParse('2400:6180:0:d2:0:2:8351:9000');
      print('tryParse IPv6: $addr1');
      expect(addr1, isNotNull);
      
      final addr2 = InternetAddress.tryParse('152.42.240.103');
      print('tryParse IPv4: $addr2');
      expect(addr2, isNotNull);
    });
  });
}

