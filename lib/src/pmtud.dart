import 'dart:math';

import 'cid.dart';
import 'packet.dart';

/// The default minimum MTU, based on IPv6 standards.
const int defaultMinMtu = 1280;

/// The default maximum MTU to probe for.
const int defaultMaxMtu = 1500;

/// Represents the state of the Path MTU Discovery process.
enum PmtudState {
  /// The initial state before any probing has begun.
  initial,

  /// The state where the controller is actively sending probes to find the MTU.
  searching,

  /// The state where the MTU has been validated and is considered stable.
  validated,
}

/// Implements Datagram Packetization Layer Path MTU Discovery (DPLPMTUD)
/// as described in RFC 8899.
///
/// This controller manages the state and logic for discovering and maintaining
/// the maximum transmission unit (MTU) for a network path.
class PathMtuDiscoveryController {
  /// The minimum MTU to consider for the path.
  final int minMtu;

  /// The maximum MTU to consider for the path.
  final int maxMtu;

  /// The current state of the PMTUD process.
  PmtudState _state = PmtudState.initial;
  PmtudState get state => _state;

  /// The currently validated and usable MTU for the path.
  int _currentMtu;
  int get currentMtu => _currentMtu;

  /// The size of the next probe packet to be sent.
  int _probeMtu = 0;

  /// A map to track in-flight probes by their packet sequence number.
  final Map<int, int> _inFlightProbes = {};

  PathMtuDiscoveryController({
    this.minMtu = defaultMinMtu,
    this.maxMtu = defaultMaxMtu,
  }) : _currentMtu = minMtu;

  /// Builds a UDX packet to be used as an MTU probe.
  ///
  /// The packet is padded with an `MtuProbeFrame` to reach the desired probe size.
  /// Returns the packet and its sequence number.
  (UDXPacket, int) buildProbePacket(ConnectionId destCid, ConnectionId srcCid,
      int destId, int srcId, int sequence) {
    // Start with the base MTU and search upwards.
    if (_state == PmtudState.initial) {
      _probeMtu = minMtu;
      _state = PmtudState.searching;
    }

    // The size of the probe frame needs to account for the UDX packet header.
    // v2 header format: version(4) + dcidLen(1) + dcid(8) + scidLen(1) + scid(8) + seq(4) + destId(4) + srcId(4) = 34 bytes
    final frameSize = _probeMtu - 34; // 34 bytes for the UDX v2 header with default CID length
    if (frameSize <= 0) {
      // This should not happen with reasonable MTU values.
      throw StateError('Calculated frame size for MTU probe is not positive.');
    }

    final probePacket = UDXPacket(
      destinationCid: destCid,
      sourceCid: srcCid,
      destinationStreamId: destId,
      sourceStreamId: srcId,
      sequence: sequence,
      frames: [MtuProbeFrame(probeSize: frameSize)],
    );

    _inFlightProbes[sequence] = _probeMtu;
    return (probePacket, sequence);
  }

  /// Handles the acknowledgment of a packet that was an MTU probe.
  ///
  /// This method updates the current MTU and adjusts the search state.
  void onProbeAcked(int sequence) {
    if (!_inFlightProbes.containsKey(sequence)) return;

    final ackedProbeSize = _inFlightProbes.remove(sequence)!;

    // The probe was successful, so this size is now our validated MTU.
    _currentMtu = ackedProbeSize;

    // Continue searching for a larger MTU using a binary search approach.
    // The next probe size is halfway between the current and max MTU.
    // We add 1 to round up, ensuring the search doesn't get stuck.
    final nextProbeSize = (_currentMtu + maxMtu + 1) ~/ 2;

    if (nextProbeSize > _currentMtu) {
      _probeMtu = nextProbeSize;
      _state = PmtudState.searching;
    } else {
      // We have reached the maximum or can't probe further.
      _state = PmtudState.validated;
    }
  }

  /// Handles the loss of a packet that was an MTU probe.
  ///
  /// This method adjusts the search range downwards.
  void onProbeLost(int sequence) {
    if (!_inFlightProbes.containsKey(sequence)) return;

    final lostProbeSize = _inFlightProbes.remove(sequence)!;

    // The probe of size `lostProbeSize` failed. The new maximum we should
    // try is one less than the failed size.
    final newMax = lostProbeSize - 1;

    // The next probe should be halfway between the last known good MTU
    // and the new maximum.
    _probeMtu = (_currentMtu + newMax) ~/ 2;

    if (_probeMtu <= _currentMtu) {
      // The search has concluded.
      _state = PmtudState.validated;
    } else {
      _state = PmtudState.searching;
    }
  }

  /// Determines if a new probe should be sent based on the current state.
  bool shouldSendProbe() {
    // For now, we only send probes during the initial search.
    // A more advanced implementation would periodically re-probe.
    return _state == PmtudState.searching && _inFlightProbes.isEmpty;
  }
}
