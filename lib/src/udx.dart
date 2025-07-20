import 'dart:async';
import 'dart:typed_data';
import 'package:collection/collection.dart';

import 'socket.dart';
import 'stream.dart';
import 'events.dart';

/// The main UDX class that provides reliable, multiplexed, and congestion-controlled
/// streams over UDP.
class UDX {
  /// Creates a new UDX instance.
  UDX();

  /// Creates a new UDX stream.
  /// 
  /// [id] - The stream ID.
  /// [framed] - If true, the stream will use framed mode.
  /// [initialSeq] - The initial sequence number.
  /// [firewall] - Optional firewall function.
  UDXStream createStream(
    int id, {
    bool framed = false,
    int initialSeq = 0,
  }) {
    return UDXStream(
      this,
      id,
      framed: framed,
      initialSeq: initialSeq,
    );
  }

  /// Returns true if the host is an IPv4 address.
  static bool isIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
    }
    return true;
  }

  /// Returns true if the host is an IPv6 address.
  static bool isIPv6(String host) {
    // Basic IPv6 validation
    if (!host.contains(':')) return false;
    if (host.contains(':::')) return false;
    
    final parts = host.split(':');
    if (parts.length > 8) return false;
    
    for (final part in parts) {
      if (part.isEmpty) continue;
      if (int.tryParse(part, radix: 16) == null) return false;
    }
    return true;
  }

  /// Returns the address family (4 for IPv4, 6 for IPv6, 0 for invalid).
  static int getAddressFamily(String host) {
    if (isIPv4(host)) return 4;
    if (isIPv6(host)) return 6;
    return 0;
  }
}
