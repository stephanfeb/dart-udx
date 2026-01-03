# Sequence Number Desynchronization Bug Fix

**Date:** January 3, 2026  
**Severity:** Critical  
**Affected Versions:** All versions prior to this fix  
**Impact:** Complete data flow blockage on affected streams

---

## Executive Summary

A critical bug in the sequence number management of `dart-udx` caused permanent data flow blockages when non-reliable packets (ACKs, window updates, resets, probes) were lost in transit. The fix ensures these packets no longer consume new sequence numbers, preventing sequence gaps that cannot be filled.

---

## Problem Statement

### Background: How UDX Sequence Numbers Work

UDX is a reliable, ordered transport protocol over UDP. Like QUIC, it assigns a monotonically increasing **sequence number** to each packet. The receiver uses these numbers to:

1. **Detect packet loss** - gaps in the sequence indicate missing packets
2. **Reorder packets** - out-of-order packets are buffered until gaps are filled
3. **Generate acknowledgments** - ACK frames reference sequence numbers

The receiver maintains a critical variable: `_nextExpectedSeq`. It only processes packets where `packet.sequence == _nextExpectedSeq`. Packets with higher sequence numbers are buffered as "out-of-order" until the gap is resolved.

### The Bug

Several types of **non-reliable packets** were incorrectly consuming new sequence numbers from `PacketManager.nextSequence`:

| Packet Type | Location | Purpose | Should Be Retransmitted? |
|-------------|----------|---------|-------------------------|
| ACK | `UDXStream._sendAck()` | Acknowledge received data | ❌ No |
| Window Update | `UDXStream.setWindow()` | Update flow control window | ❌ No |
| Reset | `UDXStream.reset()` | Terminate stream abruptly | ❌ No |
| Probe/Ping | `PacketManager.sendProbe()` | Elicit acknowledgment | ❌ No |

These packets were:
1. Getting a **new sequence number** via `packetManager.nextSequence`
2. Being **sent directly** via `socket.send()` without registration
3. **NOT being registered** with `PacketManager.sendPacket()` for retransmission

### The Fatal Scenario

```
Timeline:
─────────────────────────────────────────────────────────────────────

SENDER                                              RECEIVER
──────                                              ────────

1. Send DATA packet (seq=10)        ──────────────►  Receive seq=10 ✅
   Registered for retransmission                     _nextExpectedSeq = 11

2. Send ACK packet (seq=11)         ──────X          (Lost in transit)
   NOT registered                                    Still expecting seq=11

3. Send DATA packet (seq=12)        ──────────────►  Receive seq=12
   Registered for retransmission                     But 12 > 11, so BUFFERED

4. Send DATA packet (seq=13)        ──────────────►  Receive seq=13
   Registered for retransmission                     But 13 > 11, so BUFFERED

... time passes ...

5. Retransmission timer fires for seq=10, 12, 13
   ACK (seq=11) is NEVER retransmitted because it wasn't registered!

RESULT: _nextExpectedSeq stuck at 11 FOREVER
        All subsequent data permanently buffered
        Stream is effectively dead
```

### Visual Representation

```
Sender's Sequence Space:
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ 10 │ 11 │ 12 │ 13 │ 14 │ 15 │ 16 │... │
│DATA│ACK │DATA│DATA│ACK │DATA│ACK │    │
│ ✓  │ ✗  │ ✓  │ ✓  │ ✗  │ ✓  │ ✗  │    │  ✓ = registered, ✗ = not registered
└────┴────┴────┴────┴────┴────┴────┴────┘

Receiver's View:
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ 10 │ 11 │ 12 │ 13 │ 14 │ 15 │ 16 │... │
│ ✅ │ ❓ │ 📦 │ 📦 │ ❓ │ 📦 │ ❓ │    │  ✅ = processed, ❓ = missing, 📦 = buffered
└────┴────┴────┴────┴────┴────┴────┴────┘
      ↑
      └── _nextExpectedSeq stuck here forever
```

### Real-World Impact

This bug was discovered in the context of **Yamux multiplexing over Noise-encrypted UDX connections** in `dart-libp2p`. The symptom was:

1. First Yamux stream opens successfully
2. Large data transfer occurs (many ACK packets sent)
3. First stream closes normally
4. **Second stream fails to open** - the Yamux SYN packet is received but buffered forever

The logs showed:
```
[UDXStream] ⏳ BUFFERING out-of-order packet: Seq=96, ExpectedSeq=68
```

A gap of 28 sequence numbers had accumulated from lost ACK packets during the data transfer, permanently blocking subsequent communication.

---

## The Fix

### Principle

Non-reliable packets (those not registered for retransmission) should **not consume new sequence numbers**. Instead, they should reuse the sequence number of the last successfully sent data packet.

The receiver handles this gracefully:
- If the sequence is less than `_nextExpectedSeq`, it's treated as an "old/duplicate" packet
- The receiver still processes the frame contents (ACK, WindowUpdate, etc.)
- But it doesn't wait for this sequence number in the expected sequence

### Code Changes

#### 1. `lib/src/stream.dart` - `_sendAck()` (Already fixed)

```dart
// FIX: ACK-only packets should NOT consume new sequence numbers.
// ACKs are not retransmitted, don't need reliability guarantees, and don't carry
// ordered payload. Using new sequence numbers for ACKs causes sequence gaps at
// the receiver when ACKs are lost or arrive out-of-order, permanently blocking
// data delivery since the receiver's _nextExpectedSeq can never advance.
final ackSequence = packetManager.lastSentPacketNumber >= 0 
    ? packetManager.lastSentPacketNumber 
    : 0;

final ackPacket = UDXPacket(
  // ...
  sequence: ackSequence,  // ← Reuses last data packet's sequence
  frames: [ackFrame],
);
```

#### 2. `lib/src/stream.dart` - `setWindow()`

```dart
// FIX: Window update packets should NOT consume new sequence numbers.
// Like ACKs, they are not retransmitted and don't need reliability.
final windowUpdateSeq = packetManager.lastSentPacketNumber >= 0 
    ? packetManager.lastSentPacketNumber 
    : 0;

final windowUpdatePacket = UDXPacket(
  // ...
  sequence: windowUpdateSeq,  // ← Reuses last data packet's sequence
  frames: [WindowUpdateFrame(windowSize: _receiveWindow)],
);
```

#### 3. `lib/src/stream.dart` - `reset()`

```dart
// FIX: Reset packets should NOT consume new sequence numbers.
// Like ACKs, they are fire-and-forget and not retransmitted.
final resetSeq = packetManager.lastSentPacketNumber >= 0 
    ? packetManager.lastSentPacketNumber 
    : 0;

final resetPacket = UDXPacket(
  // ...
  sequence: resetSeq,  // ← Reuses last data packet's sequence
  frames: [ResetStreamFrame(errorCode: errorCode)],
);
```

#### 4. `lib/src/packet.dart` - `sendProbe()`

```dart
/// Sends a probe packet to elicit an ACK.
void sendProbe(ConnectionId destCid, ConnectionId srcCid, int destId, int srcId) {
  // FIX: Probe packets should NOT consume new sequence numbers.
  // Like ACKs, they are not registered for retransmission.
  final probeSeq = lastSentPacketNumber >= 0 ? lastSentPacketNumber : 0;
  
  final probePacket = UDXPacket(
    // ...
    sequence: probeSeq,  // ← Reuses last data packet's sequence
    frames: [PingFrame()],
  );
  onSendProbe?.call(probePacket);
}
```

---

## Verification

### Test Results

After applying the fix:

```
$ dart test test/transport/yamux_udx_integration_test.dart
00:09 +9: All tests passed!
```

All 9 integration tests pass, including the previously failing:
- **"should maintain Noise encryption state across rapid vs delayed writes"** - Tests sequential stream reuse over Yamux + Noise + UDX

### Log Evidence

Before fix (sequence gap accumulating):
```
[UDXStream] ✅ SEQUENTIAL packet Seq=67
[UDXStream] ⏳ BUFFERING out-of-order packet: Seq=96, ExpectedSeq=68
[UDXStream] ⏳ BUFFERING out-of-order packet: Seq=97, ExpectedSeq=68
```

After fix (ACKs handled as duplicates, data flows normally):
```
[UDXStream] ✅ SEQUENTIAL packet Seq=67
[UDXStream] ⚠️ OLD/DUPLICATE packet: Seq=67, ExpectedSeq=68  ← ACK reusing seq
[UDXStream] ✅ SEQUENTIAL packet Seq=68
```

---

## Lessons Learned

1. **Sequence numbers are precious** - Only packets that need reliability guarantees should consume them
2. **Fire-and-forget packets should be obvious** - Consider adding a flag or separate method for unreliable sends
3. **Protocol invariants matter** - The invariant "every sequence number will eventually be delivered or retransmitted" was violated
4. **Integration tests catch protocol bugs** - Unit tests on individual components wouldn't have caught this systemic issue

---

## Related Files

- `lib/src/stream.dart` - Main UDX stream implementation
- `lib/src/packet.dart` - Packet and frame definitions, PacketManager
- `lib/src/socket.dart` - UDX socket management

## References

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000.html) - Section 12.3 discusses packet number spaces
- [dart-libp2p](https://github.com/stephanfeb/dart-libp2p) - Where this bug was discovered

