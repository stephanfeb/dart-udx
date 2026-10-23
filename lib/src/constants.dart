/// Constants and configuration values for dart-udx
/// 
/// This file centralizes magic numbers and configuration parameters
/// used throughout the UDX implementation.

// =============================================================================
// Transport Parameters
// =============================================================================

/// Initial maximum data that can be sent on the connection (1 MB)
const int initialMaxData = 1024 * 1024;

/// Initial maximum data that can be sent on a stream (64 KB)
const int initialMaxStreamData = 65536;

/// Initial maximum number of concurrent bidirectional streams
const int initialMaxStreams = 100;

/// Maximum ACK delay in milliseconds (RFC 9002)
const int maxAckDelay = 25;

/// ACK delay exponent for encoding ACK delay field
const int ackDelayExponent = 3;

// =============================================================================
// Error Codes
// =============================================================================

/// No error - graceful close
const int errorNoError = 0x00;

/// Internal error
const int errorInternalError = 0x01;

/// Stream limit exceeded
const int errorStreamLimitError = 0x02;

/// Flow control error
const int errorFlowControlError = 0x03;

/// Protocol violation
const int errorProtocolViolation = 0x04;

/// Invalid connection migration
const int errorInvalidMigration = 0x05;

/// Connection timeout
const int errorConnectionTimeout = 0x06;

// =============================================================================
// Timeouts
// =============================================================================

/// The smoothed RTT before the first sample (RFC 9002 section 6.2.2), with
/// [initialRttVar] its variation: the first PTO is about a second. The
/// estimate used to start at 100 ms, so on a slow path the first probe went
/// out before the handshake could answer.
const Duration initialRtt = Duration(milliseconds: 333);
const Duration initialRttVar = Duration(microseconds: 166500);

/// Maximum idle timeout before closing connection
const Duration maxIdleTimeout = Duration(seconds: 30);

/// Maximum time to wait for handshake completion
const Duration handshakeTimeout = Duration(seconds: 10);

// =============================================================================
// Congestion Control
// =============================================================================

/// The largest datagram stream data goes out in: what any internet path
/// carries, as QUIC's 1200 (RFC 9000 section 14), so it fits the 1280-byte
/// IPv6 minimum MTU with its headers. Mobile carriers' tunnels (464XLAT,
/// GTP) carry less than 1500 and drop a larger datagram that may not be
/// fragmented: a write of more than one full datagram then never arrives,
/// and the connection is given up. go-udx sends the same size.
const int safeDatagramSize = 1200;

/// A stream packet's bytes besides its data: the packet header with both
/// connection IDs at their longest (20 bytes each), and the stream frame's
/// header.
const int streamPacketOverhead = 70;

/// Maximum datagram size (typical MTU minus IP/UDP headers)
const int maxDatagramSize = 1472;

/// Minimum congestion window size (in bytes)
const int minCongestionWindow = 2 * maxDatagramSize;

/// Initial congestion window size (10 packets as per RFC 9002)
const int initialCongestionWindow = 10 * maxDatagramSize;

/// Maximum congestion window size (to prevent overflow)
const int maxCongestionWindow = 1000 * maxDatagramSize;

/// Loss detection threshold (as fraction, 9/8 = 1.125)
const double lossDetectionThresholdNum = 9;
const double lossDetectionThresholdDen = 8;

// =============================================================================
// Path MTU Discovery
// =============================================================================

// In datagram bytes: the search probes up from [safeDatagramSize] towards
// [maxDatagramSize] (MtuDiscovery), as go-udx does.

/// How many times a probe size is lost before it is ruled out: one loss is
/// as likely congestion as a path that cannot carry it.
const int mtuProbeTries = 3;

/// The search ends once the validated size is this close to one that failed.
const int mtuSearchStep = 16;

/// How many full-size data packets must be lost in a row, with none
/// acknowledged in between, before the path is taken to have shrunk.
const int blackholePackets = 3;

/// The same conclusion from probe timeouts, when nothing at all is
/// acknowledged any more.
const int blackholePtos = 3;

/// How long after a black hole the search starts over.
const Duration blackholeRetry = Duration(minutes: 1);

// =============================================================================
// Anti-Amplification
// =============================================================================

/// Amplification factor for anti-amplification limits (RFC 9000)
const int amplificationFactor = 3;

/// Minimum bytes received before considering address validated
const int minBytesForValidation = 1000;

// =============================================================================
// Stream Management
// =============================================================================

/// Default stream priority (0-255, lower = higher priority)
const int defaultStreamPriority = 128;

/// Maximum stream priority value
const int maxStreamPriority = 255;

// =============================================================================
// Connection IDs
// =============================================================================

/// Minimum Connection ID length
const int minCidLength = 0;

/// Maximum Connection ID length
const int maxCidLength = 20;

/// Default Connection ID length (for backward compatibility)
const int defaultCidLength = 8;

// =============================================================================
// Stateless Reset
// =============================================================================

/// Length of stateless reset token
const int statelessResetTokenLength = 16;

/// Minimum packet size for stateless reset
const int minStatelessResetPacketSize = 39;

// Version numbers are defined once, canonically, in `UdxVersion` (version.dart).
// A second copy lived here and had drifted to v2 while the wire moved to v3,
// which is exactly the kind of contradiction a duplicate invites. Use
// `UdxVersion.current` / `UdxVersion.supportedVersions`.

