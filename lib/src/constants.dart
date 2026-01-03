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

/// Initial RTT estimate (RFC 9002 recommends 333ms)
const Duration initialRtt = Duration(milliseconds: 333);

/// Maximum idle timeout before closing connection
const Duration maxIdleTimeout = Duration(seconds: 30);

/// Maximum time to wait for handshake completion
const Duration handshakeTimeout = Duration(seconds: 10);

// =============================================================================
// Congestion Control
// =============================================================================

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

/// Minimum MTU to probe (IPv6 minimum)
const int minMtu = 1280;

/// Maximum MTU to probe (common Ethernet MTU minus headers)
const int maxMtu = 1500;

/// MTU probe timeout
const Duration mtuProbeTimeout = Duration(seconds: 2);

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

// =============================================================================
// Version Numbers
// =============================================================================

/// UDX Protocol Version 1 (original with fixed 8-byte CIDs)
const int udxVersionV1 = 0x00000001;

/// UDX Protocol Version 2 (variable CIDs, enhanced QUIC compliance)
const int udxVersionV2 = 0x00000002;

/// Current UDX protocol version
const int udxVersionCurrent = udxVersionV2;

