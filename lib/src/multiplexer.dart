import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:meta/meta.dart';

import 'udx.dart';
import 'metrics_observer.dart';

/// A class that demultiplexes incoming UDX packets to the correct `UDPSocket`.
///
/// The `UDXMultiplexer` listens on a single `RawDatagramSocket` and forwards
/// packets to the appropriate `UDPSocket` instance based on their destination
/// Connection ID (CID).
class UDXMultiplexer {
  UDXMultiplexer(this.socket, {this.metricsObserver}) {
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = false; // We'll enable when needed
    _listen();
  }

  /// The underlying UDP socket that this multiplexer listens on.
  final RawDatagramSocket socket;
  
  /// Optional metrics observer to be passed to all created sockets
  final UdxMetricsObserver? metricsObserver;

  final _connectionsController = StreamController<UDPSocket>.broadcast();

  /// A stream of incoming UDX sockets.
  Stream<UDPSocket> get connections => _connectionsController.stream;

  /// A map of active connections, keyed by their local Connection ID.
  @visibleForTesting
  final Map<ConnectionId, UDPSocket> socketsByCid = {};
  @visibleForTesting
  final Map<String, UDPSocket> socketsByPeer = {};
  
  /// A map of stateless reset tokens for known connections.
  /// Used to validate incoming stateless reset packets.
  final Map<ConnectionId, StatelessResetToken> _resetTokens = {};

  /// Starts listening for incoming datagrams and routes them.
  void _listen() {
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram == null) return;

        final data = datagram.data;
        // New packet format minimum: version(4) + dcidLen(1) + scidLen(1) + seq(4) + destId(4) + srcId(4) = 18 bytes
        if (data.length < 18) return; // Not a valid UDX packet

        // Check if this might be a stateless reset packet
        if (data.length >= StatelessResetPacket.minPacketSize) {
          final resetPacket = StatelessResetPacket.tryParse(data);
          if (resetPacket != null) {
            // Check if we have this token registered
            for (final entry in _resetTokens.entries) {
              if (entry.value == resetPacket.token) {
                // Valid stateless reset received
                final socket = socketsByCid[entry.key];
                if (socket != null) {
                  // Close the socket due to stateless reset
                  socket.closeWithError(
                    UdxErrorCode.internalError,
                    'Received stateless reset from peer',
                  );
                }
                return;
              }
            }
          }
        }

        // Extract the destination CID from the new packet header format
        // New format: version(4) + dcidLen(1) + dcid(0-20) + ...
        ConnectionId destinationCid;
        try {
          final dcidLength = data[4]; // Byte at offset 4 is destination CID length
          if (dcidLength > 20 || data.length < 5 + dcidLength) {
            return; // Invalid packet
          }
          destinationCid = ConnectionId(data.sublist(5, 5 + dcidLength));
        } catch (e) {
          return; // Failed to parse CID, ignore packet
        }

        // Route the packet to the correct socket
        final socketConnection = socketsByCid[destinationCid];
        
        if (socketConnection != null) {
          // print('[MUX] Forwarding packet to existing UDPSocket');
          socketConnection.handleIncomingDatagram(datagram.data, datagram.address, datagram.port);
        } else {
          try {
            final packet = UDXPacket.fromBytes(data);
            final isNewConnection = packet.frames
                .whereType<StreamFrame>()
                .any((frame) => frame.isSyn);
            
            if (isNewConnection) {
              // A new connection, identified by the CID the dialer chose for
              // us. A socket this side created for the same address with
              // createSocket, and which hasn't heard from the peer yet, is the
              // same connection being opened from both ends (simultaneous
              // open), so the SYN joins it. Anything else is a separate
              // connection and gets its own socket: go-udx and js-udx dial
              // several connections from one shared socket, and mapping a new
              // CID onto an existing connection made the two cross-talk.
              final peerKey = '${datagram.address.address}:${datagram.port}';
              final pending = socketsByPeer[peerKey];
              final UDPSocket newSocket;
              if (pending != null && !pending.isServer && !pending.isHandshakeCompleted) {
                newSocket = pending;
                socketsByCid[destinationCid] = newSocket;
              } else {
                newSocket = _newSocket(
                  UDX(),
                  datagram.address.address,
                  datagram.port,
                  localCid: destinationCid,
                  remoteCid: packet.sourceCid,
                  isServer: true,
                );
              }
              _connectionsController.add(newSocket);
              newSocket.handleIncomingDatagram(datagram.data, datagram.address, datagram.port);
            }
          } catch (e) {
            // Not a valid UDX packet, ignore.
          }
        }
      }
    });
  }

  /// Closes the multiplexer and all associated sockets.
  void close() {
    // Create a copy of the list of sockets to avoid concurrent modification
    final socketsToClose = List<UDPSocket>.from(socketsByCid.values);
    for (final s in socketsToClose) {
      s.close();
    }
    socketsByCid.clear();
    socket.close();
    _connectionsController.close();
  }

  /// Sends a datagram to the specified address and port.
  void send(Uint8List data, InternetAddress address, int port) {
    socket.send(data, address, port);
  }

  /// Removes a socket from the multiplexer's management.
  void removeSocket(ConnectionId localCid) {
    final socket = socketsByCid.remove(localCid);
    if (socket != null) {
      final peerKey = '${socket.remoteAddress.address}:${socket.remotePort}';
      // The address may have other connections; only forget it for this one.
      if (identical(socketsByPeer[peerKey], socket)) socketsByPeer.remove(peerKey);
    }
  }

  /// Registers an existing socket with this multiplexer.
  /// Used for connection migration.
  void addSocket(UDPSocket socket) {
    if (socketsByCid.containsKey(socket.cids.localCid)) {
      // This case should be handled by the caller, e.g., by closing the old socket.
      // For now, we'll just log it.
      print('Warning: CID collision detected in addSocket.');
      return;
    }
    socketsByCid[socket.cids.localCid] = socket;
  }

  /// Creates or retrieves a `UDPSocket` for a given peer.
  ///
  /// For dialing: a second call for the same `host:port` returns the first
  /// socket. Inbound connections don't go through this; each one gets its own
  /// socket, keyed by its connection ID.
  UDPSocket createSocket(
    UDX udx,
    String host,
    int port, {
    ConnectionId? localCid,
    ConnectionId? remoteCid,
    bool isServer = false,
  }) {
    final peerKey = '$host:$port';
    final existing = socketsByPeer[peerKey];
    if (existing != null) return existing;
    return _newSocket(udx, host, port, localCid: localCid, remoteCid: remoteCid, isServer: isServer);
  }

  UDPSocket _newSocket(
    UDX udx,
    String host,
    int port, {
    ConnectionId? localCid,
    ConnectionId? remoteCid,
    bool isServer = false,
  }) {
    final effectiveLocalCid = localCid ?? ConnectionId.random();
    final effectiveRemoteCid = remoteCid ?? ConnectionId.random();
    final newSocket = UDPSocket(
      udx: udx,
      multiplexer: this,
      remoteAddress: InternetAddress(host),
      remotePort: port,
      cids: ConnectionCids(effectiveLocalCid, effectiveRemoteCid),
      metricsObserver: metricsObserver,
      isServer: isServer,
    );
    socketsByCid[effectiveLocalCid] = newSocket;
    socketsByPeer.putIfAbsent('$host:$port', () => newSocket);
    return newSocket;
  }

  /// Sends a stateless reset packet to a peer.
  /// 
  /// This is used when the server has lost connection state but receives
  /// a packet for a connection. The stateless reset allows the client to
  /// quickly detect that the server has lost state and close the connection.
  void sendStatelessReset(
    InternetAddress address,
    int port,
    ConnectionId connectionId,
  ) {
    try {
      // Generate token for this CID if not already cached
      StatelessResetToken token;
      if (_resetTokens.containsKey(connectionId)) {
        token = _resetTokens[connectionId]!;
      } else {
        token = StatelessResetToken.generate(connectionId);
        _resetTokens[connectionId] = token;
      }
      
      // Create and send stateless reset packet
      final resetPacket = StatelessResetPacket.create(token);
      socket.send(resetPacket.toBytes(), address, port);
    } catch (e) {
      // Silently fail if we can't send stateless reset
      // (e.g., server secret not configured)
    }
  }
  
  /// Registers a reset token for a connection.
  /// This allows the multiplexer to validate incoming stateless resets.
  void registerResetToken(ConnectionId cid, StatelessResetToken token) {
    _resetTokens[cid] = token;
  }

  // --- Test Hooks ---
  Map<ConnectionId, UDPSocket> getSocketsForTest() => socketsByCid;

  void handleIncomingDatagramForTest(
      Uint8List data, InternetAddress address, int port) {
    // This is a simplified version of the logic in _listen for test purposes
    if (data.length < 18) return; // New minimum packet size

    // Extract destination CID from new packet format
    ConnectionId destinationCid;
    try {
      final dcidLength = data[4]; // Byte at offset 4 is destination CID length
      if (dcidLength > 20 || data.length < 5 + dcidLength) {
        return; // Invalid packet
      }
      destinationCid = ConnectionId(data.sublist(5, 5 + dcidLength));
    } catch (e) {
      return; // Failed to parse CID, ignore packet
    }

    final socketConnection = socketsByCid[destinationCid];

    if (socketConnection != null) {
      socketConnection.handleIncomingDatagram(data, address, port);
    } else {
      try {
        final packet = UDXPacket.fromBytes(data);
        final isNewConnection =
            packet.frames.whereType<StreamFrame>().any((frame) => frame.isSyn);

        if (isNewConnection) {
          final newSocket = createSocket(
            UDX(),
            address.address,
            port,
            localCid: destinationCid, // Use the CID from the SYN packet
            remoteCid: packet.sourceCid,
          );
          // THE FIX: Map the temporary destination CID to the new socket
          // to handle retransmissions during the handshake.
          socketsByCid[destinationCid] = newSocket;
          _connectionsController.add(newSocket);
          newSocket.handleIncomingDatagram(data, address, port);
        }
      } catch (e) {
        // Ignore
      }
    }
  }
}
