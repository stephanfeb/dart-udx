# Changelog

All notable changes to dart-udx will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0] - 2026-10-02

Interoperability fixes found while porting UDX to TypeScript (js-udx), checked
against go-udx and js-udx over real UDP.

### Fixed

- **Several streams on one connection no longer collapse into the first.** A stream a peer opened was registered under the destination id the peer used. go-udx and js-udx never learn our id for a stream they open and address it to 0 throughout, as does dart-udx's own dialer, so every such stream became stream 0: a second one, concurrent or opened while the first was still closing, was routed into the first, its packets acknowledged and its bytes dropped, and it hung until the idle timeout. A stream a peer opens now gets the id the peer named if that is free (dart-libp2p names both ids of its first stream), or else the next free even id, as a go-udx acceptor would; its SYN-ACK carries that id.
- **Frame types use go-udx's wire codes.** They were written as the `FrameType` enum's index, which has no gap at 0x0c, so every type from STOP_SENDING up was one below go-udx's and js-udx's. Those peers rejected our STOP_SENDING, and we misread their STREAM_DATA_BLOCKED (0x0f) as NEW_CONNECTION_ID and dropped the packet. `FrameType` now carries an explicit `code` (`FrameType.fromCode`).
- **STREAM_DATA_BLOCKED is answered**, as go-udx does, by re-advertising the stream's current limit. It is how go-udx and js-udx recover a stream whose WINDOW_UPDATE was lost. RESET_STREAM, STOP_SENDING, WINDOW_UPDATE and STREAM_DATA_BLOCKED are routed like STREAM frames, falling back to the sender's stream id.
- **ACK frames never overflow their one-byte gap and range counts.** `AckFrame.fromReceived` stops at a gap over 255 or at 255 ranges, and `toBytes` throws rather than silently truncating.
- **Connections from the same address stay apart.** go-udx and js-udx dial every connection from one shared socket. An inbound SYN from an address with an existing connection joined that connection unless it was a genuine simultaneous open; it now gets its own socket, keyed by connection id.

### Added

- `UDPSocket.isServer`, `UDPSocket.isHandshakeCompleted`, `UDPSocket.allocateIncomingStreamId`, `UDXStream.deliverStreamDataBlocked`, `AckFrame.fromReceived`, `FrameType.code` and `FrameType.fromCode`.

### Compatibility

The wire version is still 3. Between 3.1.0 and 3.0.0 peers, STOP_SENDING (sent by `UDXStream.stopReceiving`) is lost in both directions, since the two number it differently; nothing else dart-udx sends changed. go-udx and js-udx interoperate fully only with 3.1.0.

## [3.0.0] - 2026-09-23

### Breaking

- **Wire protocol v3: STREAM frames carry a byte offset and each stream reassembles its own bytes.** Ordering used to happen at the socket, on the connection's packet sequence number, so a gap belonging to one stream stalled delivery on every other stream sharing the connection. That matters here more than in Go, because dart-libp2p uses UDX directly as its libp2p stream multiplexer, so concurrent streams are the normal case.
  **v3 does not interoperate with v2 (2.0.x), and both ends must be upgraded together.** The eight offset bytes sit where a v2 parser expects the data length, so a v2 peer does not fail on a v3 frame: it reads a plausible wrong length and hands nonsense to the application. The version is therefore checked on receive and packets of an unsupported version are dropped, which makes a mismatch look like an unreachable peer rather than corruption. go-udx carries the matching change; the two are a flag day.
- **FIN carries the stream's final size.** FIN is a flag on a frame that can overtake data still in flight, so closing on its arrival truncated the tail. A stream now ends when its delivered bytes reach that size.
- **`UDXStream.data` counts consumption, and a slow reader now throttles the sender.** The getter returns a cached mapped view of the underlying stream that counts each chunk as it is delivered. With no listener, or a paused subscription, events sit in the controller, nothing is counted, the advertised offset stops advancing and the sender stalls. That is the point: inbound transfers previously had no stream-level back-pressure at all.
- **`setWindow` sets a window size rather than an absolute offset.** It cannot revoke credit already granted: it advertises `bytesConsumed + newSize`, and because the peer applies offsets monotonically, a smaller size takes effect only once the peer catches up to the offset it already holds.

### Fixed

- **Stream flow control did not bind on upload.** WINDOW_UPDATE carries an absolute offset, the highest cumulative byte position the peer will accept, but the sender compared it against `inflight`, the bytes currently outstanding, which also happens to be the connection-level counter. Against an offset that grows for the life of the stream, that comparison stops binding almost immediately, leaving the congestion window as the only limit. Measured against a peer with a deliberately slow reader, the sender ran 3.9x past the offset it had been granted. It now gates on the per-stream `bytesWritten`.
- **Offsets survive the 4GB wrap.** The frame field is a uint32, so an offset is transmitted modulo 2^32. The receiver recovers the full value by choosing the candidate nearest the limit it already holds (RFC 1982 serial-number arithmetic), which is unambiguous because the true offset is always within one receive window of the current limit. Clamping instead would stall a stream permanently at 4GB. Updates are applied monotonically, so a stale or reordered frame can never revoke granted credit.
- **The receive window tracked bytes received rather than bytes consumed**, so a receiver kept granting credit whether or not the application was reading. A sender pushing 16MB at a reader sleeping 25ms between chunks had all 16,777,216 bytes accepted while the application had consumed 143,740. The window is now anchored to consumption, advertised as an absolute offset, and doubles per update up to 4MB. The same push now moves 361,980 bytes against 151,972 consumed. This supersedes the fixed-threshold workaround added in 2.0.3's line of development.
- **Loss recovery follows QUIC.** A retransmitted packet is re-keyed under a fresh sequence number and the give-up cap is removed, mirroring the go-udx fix. `sentTime` is deliberately not reset, since it is read only for persistent-congestion detection and RTT sampling uses a separate map, so retransmits correctly take no RTT sample.
- **Idle connections are now closed by a backstop timeout** of `max(maxIdleTimeout, 3xPTO)`, self-rearming, which resets streams silently and logs the close reason.
- **A stream is opened by a data frame, not only by SYN.** Opening on SYN alone was safe only while socket-level ordering guaranteed the SYN arrived first. A bare FIN deliberately still does not open one, since it carries nothing to deliver.
- **Packets are routed by the sender's stream id when the destination id is unknown.** A peer that has not yet learned our local id addresses its first packets to 0, so the same stream could arrive under two ids and open twice.
- **`UDXPacket.currentVersion` was a second hardcoded copy of the version number** that silently disagreed with `UdxVersion.current` the moment either was bumped. It now aliases it.
- **The out-of-order buffer's backstop sits above the largest receive window** rather than at it, and overrunning it fails the stream rather than silently dropping bytes that were already acknowledged and so will never be re-sent.
- **SocketException from the multiplexer is handled**: the error is emitted as an event and the socket closes gracefully instead of throwing out of the send path.

### Added

- Diagnostic logging points for packet receive, ACK generation, send and small-payload delivery, gated behind `UdxLogging.info` and off by default.

## [2.0.3] - 2026-02-22

### Fixed
- Control-only stream packets (WindowUpdate) no longer consume sequence numbers, preventing permanent receiver stalls when the Go UDX peer buffers out-of-order packets waiting for a gap that can never be filled
- Fixes 64KB+ payload echo timeouts and yamux keepalive-triggered connection kills

## [2.0.2] - 2026-02-22

### Fixed
- Control-only packets (ACKs, window updates) now bypass connection-level receive ordering, preventing sequence gaps when reordered ACKs advance `_nextExpectedSeq` past data packets
- Fixes handshake failures over networks with packet reordering (mobile, satellite, congested links)

## [2.0.1] - 2026-02-17

### Fixed
- Stream-level flow control: send window updates when 25% of receive window consumed, preventing yamux mux stalls on long-lived streams
- Connection window exhaustion due to uninitialized CUBIC epoch
- Always use bidirectional stream type for incoming connections

### Changed
- Per-connection packet sequencing for QUIC RFC 9000 compliance

## [2.0.0] - 2026-01-03

### Breaking Changes

- **Variable-Length Connection IDs**: Connection IDs can now be 0-20 bytes (previously fixed at 8 bytes)
- **Updated Packet Format**: New packet header format includes version field and variable-length CID encoding
- **Protocol Version**: Bumped to v2 (0x00000002) to reflect breaking changes

### Added - Phase 1: Packet Format Foundation

- **Variable-Length Connection IDs**: Support for 0-20 byte CIDs per QUIC spec
  - `ConnectionId.minCidLength` and `ConnectionId.maxCidLength` constants
  - `ConnectionId.random(length)` factory with configurable length
  - Updated `UDXPacket` serialization to handle variable-length CIDs

- **Version Negotiation**: Full version negotiation support
  - `UdxVersion` class with v1/v2 support
  - `VersionNegotiationPacket` for incompatible version handling
  - Automatic VERSION_NEGOTIATION response for unsupported versions

- **CONNECTION_CLOSE Frame**: Graceful connection termination
  - `ConnectionCloseFrame` with error code, frame type, and reason phrase
  - `UdxErrorCode` constants for standard error codes
  - `UDPSocket.closeWithError()` method for sending CONNECTION_CLOSE
  - Automatic handling of incoming CONNECTION_CLOSE frames

- **STATELESS_RESET Mechanism**: Connection state recovery
  - `StatelessResetToken` class with HMAC-SHA256 generation
  - `StatelessResetPacket` for stateless connection termination
  - `UDXMultiplexer.sendStatelessReset()` method
  - Automatic detection and handling of stateless reset packets

### Added - Phase 2: Stream Management

- **Unidirectional Streams**: Half-duplex stream support
  - `StreamType` enum: bidirectional, unidirectionalLocal, unidirectionalRemote
  - `StreamIdHelper` for QUIC-style stream ID encoding
  - Automatic stream type detection from stream ID
  - Write operation validation based on stream directionality

- **STOP_SENDING Frame**: Receiver-initiated stream termination
  - `StopSendingFrame` for signaling unwanted data
  - `UDXStream.stopReceiving()` method
  - Automatic handling of incoming STOP_SENDING frames

- **BLOCKED Frames**: Flow control signaling
  - `DataBlockedFrame` for connection-level blocking
  - `StreamDataBlockedFrame` for stream-level blocking
  - Automatic BLOCKED frame transmission when flow control limits are hit
  - Events for applications to respond to blocking

- **Stream Priorities**: Priority-based stream scheduling
  - `UDXStream.priority` property (0-255, lower = higher priority)
  - `UDXStream.setPriority()` method
  - Infrastructure for future priority-based packet scheduling

### Added - Phase 3: Security Enhancements

- **Anti-Amplification Limits**: DDoS protection per RFC 9000
  - 3x amplification factor enforcement
  - Packet queueing when amplification limit is reached
  - Address validation after receiving sufficient data
  - `UDPSocket._onAddressValidated()` for flushing queued packets

- **CID Rotation Frames**: Connection ID management
  - `NewConnectionIdFrame` for providing new CIDs
  - `RetireConnectionIdFrame` for CID retirement
  - Infrastructure for future active CID rotation

### Added - Phase 4: Performance Enhancements

- **ECN Support**: Explicit Congestion Notification infrastructure
  - Optional ECN count fields in `AckFrame` (ect0Count, ect1Count, ceCount)
  - `CongestionController.processEcnFeedback()` placeholder
  - Ready for future OS-level ECN integration

- **RTT Estimation Improvements**: RFC 9002 compliance
  - `maxAckDelay` constant (25ms per RFC 9002)
  - ACK delay capping in `_updateRtt()` method
  - More accurate RTT measurements

### Added - Phase 5: Code Quality

- **Configurable Logging**: Structured logging system
  - `UdxLogging` class with debug, info, warn, error levels
  - `UdxLogger` typedef for custom logger functions
  - Verbose and info flags for log level control
  - Replacement of direct print statements

- **Constants Extraction**: Centralized configuration
  - `constants.dart` with all transport parameters
  - Error codes, timeouts, and limits
  - Improved code maintainability

### Changed

- `UDXPacket` now includes `version` field (default: `UDXPacket.currentVersion`)
- `UDXStream` constructor now accepts optional `streamType` parameter
- `UDPSocket.handleIncomingDatagram()` is now async to support CONNECTION_CLOSE handling
- Sequence number handling for non-reliable frames (ACKs, STOP_SENDING, etc.) reuses last sent sequence

### Fixed

- Sequence number desynchronization bug (documented in SEQUENCE_NUMBER_DESYNC_FIX.md)
- Linter warnings for unused variables and redundant null checks

### Migration Guide

#### For v1 → v2 Migration:

1. **Packet Format**: No action required if using default 8-byte CIDs. Variable-length CIDs are opt-in.

2. **Version Negotiation**: Clients will automatically handle VERSION_NEGOTIATION. Listen for `versionNegotiation` events if needed:
   ```dart
   socket.on('versionNegotiation', (event) {
     print('Server doesn\'t support our version: ${event['clientVersion']}');
   });
   ```

3. **Graceful Shutdown**: Replace `socket.close()` with `socket.closeWithError()` for explicit error codes:
   ```dart
   await socket.closeWithError(UdxErrorCode.noError, 'Normal close');
   ```

4. **Unidirectional Streams**: Specify stream type when creating:
   ```dart
   final stream = await UDXStream.createOutgoing(
     udx, socket, localId, remoteId, host, port,
     streamType: StreamType.unidirectionalLocal,
   );
   ```

5. **Logging**: Enable logging for debugging:
   ```dart
   UdxLogging.setDefaultLogger();
   UdxLogging.verbose = true;
   ```

### Notes

- Full CID rotation implementation requires additional state management (future enhancement)
- ECN processing awaits OS-level integration (infrastructure in place)
- Stream priority scheduling is partially implemented (priorities settable, scheduling to be enhanced)

## [0.3.1] - Previous Version

Previous changes not documented in this changelog.
