# Changelog

All notable changes to dart-udx will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
