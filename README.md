# UDX API v2 Documentation - Enhanced

## Table of Contents
1. [Overview](#1-overview)
2. [Core Concepts](#2-core-concepts)
3. [API Reference](#3-api-reference)
4. [Flow Control & Congestion Management](#4-flow-control--congestion-management)
5. [Event System](#5-event-system)
6. [Error Handling](#6-error-handling)
7. [Advanced Features](#7-advanced-features)
8. [Usage Examples](#8-usage-examples)
9. [Performance Tuning](#9-performance-tuning)
10. [Troubleshooting](#10-troubleshooting)
11. [Best Practices](#11-best-practices)

---

## 1. Overview

Welcome to the UDX Dart library, a low-level implementation of a QUIC-inspired, UDP-based transport protocol. This library provides the core building blocks for creating fast, reliable, and connection-oriented communication over UDP with advanced features like congestion control, flow control, and connection migration.

### Key Features
- **Reliable, ordered delivery** over UDP
- **CUBIC congestion control** for optimal throughput
- **Connection and stream-level flow control**
- **Connection migration** for mobile applications
- **Path MTU Discovery (PMTUD)** for optimal packet sizing
- **Packet pacing** for smooth network utilization
- **Multiple concurrent streams** per connection
- **Event-driven architecture** for responsive applications

### Architecture Overview

The central architectural pattern is a clear separation of concerns, designed to give developers maximum control over network resources and connection lifecycle:

- **`UDXMultiplexer`**: The lowest level. A single multiplexer binds to a single `RawDatagramSocket` (representing one network interface, e.g., `wlan0` or `eth0`). Routes incoming UDP packets to the correct `UDPSocket` based on their Connection ID (CID).
- **`UDPSocket`**: Represents a single, logical connection to a remote peer. Manages connection state, handshake, flow control, path validation, and stream multiplexing.
- **`UDXStream`**: Represents a single, ordered, and reliable stream of data within a `UDPSocket`. Provides congestion control, retransmission, and flow control at the stream level.

This design enables advanced features like **Connection Migration**, where a `UDPSocket` can be moved from one `UDXMultiplexer` to another without dropping the connection.

---

## 2. Core Concepts

### 2.1 Multiplexing

The `UDXMultiplexer` is the heart of I/O handling. By listening on a single UDP port, it can serve hundreds or thousands of distinct connections simultaneously. It achieves this by inspecting the Destination CID in the header of every incoming packet and forwarding it to the `UDPSocket` that owns that CID.

### 2.2 Connection & Stream Lifecycle

#### Connection Lifecycle
1. **Establishment**: A `UDPSocket` is established via a handshake process initiated by creating an outgoing `UDXStream`
2. **Active**: The connection is ready for data transfer and stream creation
3. **Migration**: The connection can be moved between network interfaces
4. **Closing**: Graceful shutdown with proper cleanup
5. **Closed**: Connection is terminated and resources are freed

#### Stream Lifecycle
1. **Creation**: Streams are created either explicitly by the client (`UDXStream.createOutgoing`) or accepted by the server via the `UDPSocket.on('stream')` event
2. **Handshake**: SYN/SYN-ACK exchange establishes the stream
3. **Data Transfer**: Reliable, ordered data transmission with flow control
4. **Closing**: Graceful shutdown with FIN frame or abrupt reset
5. **Closed**: Stream resources are cleaned up

### 2.3 Connection Migration

Connection Migration allows a connection to survive changes in the client's underlying network path (e.g., switching from Wi-Fi to cellular). The library provides the mechanisms, but the policy is left to the application.

**Migration Process:**
1. Application detects network path change
2. Creates new `RawDatagramSocket` and `UDXMultiplexer`
3. Removes `UDPSocket` from old multiplexer: `oldMux.removeSocket()`
4. Registers with new multiplexer: `newMux.addSocket()`
5. Updates socket's transport link: `socket.multiplexer = newMux`
6. Client sends packet from new path, triggering automatic path validation

### 2.4 Flow Control

UDX implements two levels of flow control:

#### Connection-Level Flow Control
- Controls total bytes in flight across all streams on a connection
- Prevents overwhelming the receiver's connection buffer
- Managed via `MAX_DATA` frames

#### Stream-Level Flow Control
- Controls bytes in flight for individual streams
- Prevents head-of-line blocking between streams
- Managed via `WINDOW_UPDATE` frames

### 2.5 Congestion Control

UDX uses the CUBIC congestion control algorithm, which:
- Provides excellent throughput on high-bandwidth, high-latency networks
- Includes slow start, congestion avoidance, and fast recovery phases
- Adapts to network conditions automatically
- Supports packet pacing for smoother transmission

---

## 3. API Reference

### 3.1 UDXMultiplexer

Manages I/O for multiple connections over a single UDP socket.

#### Constructor
```dart
UDXMultiplexer(RawDatagramSocket socket)
```
Creates a multiplexer that listens on the provided bound `RawDatagramSocket`.

#### Properties
```dart
RawDatagramSocket socket              // The underlying UDP socket
Stream<UDPSocket> get connections     // Stream of new incoming connections
```

#### Methods
```dart
UDPSocket createSocket(UDX udx, String host, int port, {
  ConnectionId? localCid,
  ConnectionId? remoteCid,
})
```
Creates a new `UDPSocket` for connecting to a remote peer.

```dart
void addSocket(UDPSocket socket)
```
Registers an existing `UDPSocket` with the multiplexer. Essential for connection migration.

```dart
void removeSocket(ConnectionId localCid)
```
Unregisters a `UDPSocket` from the multiplexer.

```dart
void send(Uint8List data, InternetAddress address, int port)
```
Sends a datagram to the specified address and port.

```dart
void close()
```
Closes the multiplexer and all associated sockets.

### 3.2 UDPSocket

Represents a single logical connection to a remote peer.

#### Properties
```dart
Future<void> get handshakeComplete    // Completes when handshake succeeds
bool get connected                    // Whether the socket is connected
bool get closing                      // Whether the socket is closing
bool get idle                         // Whether the socket has no active streams
bool get busy                         // Whether the socket has active streams
InternetAddress remoteAddress         // Remote peer's address
int remotePort                        // Remote peer's port
ConnectionCids cids                   // Connection IDs for this connection
UDXMultiplexer multiplexer           // The multiplexer managing this socket
```

#### Methods
```dart
Stream<UDXEvent> on(String event)
```
Returns a stream for a given event type. Key events:
- `'stream'`: New `UDXStream` from remote peer
- `'pathUpdate'`: Client successfully migrated to new network path
- `'close'`: Socket is closed
- `'connect'`: Socket is connected
- `'error'`: Socket-level error occurred
- `'remoteConnectionWindowUpdate'`: Remote peer updated connection window
- `'remoteMaxStreamsUpdate'`: Remote peer updated max streams limit

```dart
Map<String, dynamic>? address()
```
Returns the remote peer's address information.

```dart
void setTTL(int ttl)
```
Sets the TTL (Time To Live) for outgoing packets.

```dart
int getRecvBufferSize()
void setRecvBufferSize(int size)
```
Gets/sets the receive buffer size.

```dart
int getSendBufferSize()
void setSendBufferSize(int size)
```
Gets/sets the send buffer size.

```dart
Future<void> sendMaxDataFrame(int localMaxData, {int streamId = 0})
```
Sends a MAX_DATA frame to update the connection-level flow control window.

```dart
Future<void> sendMaxStreamsFrame()
```
Sends a MAX_STREAMS frame to update the maximum concurrent streams limit.

```dart
bool canCreateNewStream()
```
Checks if a new outgoing stream can be created within the peer's limits.

```dart
int getAvailableConnectionSendWindow()
```
Gets the available send window at the connection level.

```dart
void close()
```
Closes the connection and all its streams.

### 3.3 UDXStream

Represents a bidirectional, reliable data stream.

#### Properties
```dart
int get id                           // Local stream ID
int? remoteId                        // Remote stream ID
String? remoteHost                   // Remote host address
int? remotePort                      // Remote port
bool get connected                   // Whether stream is connected
bool get isInitiator                 // Whether this endpoint initiated the stream
int get mtu                          // Maximum transmission unit
Duration get rtt                     // Round-trip time
int get cwnd                         // Congestion window size
int get inflight                     // Bytes currently in flight
int get receiveWindow                // Local receive window size
int get remoteReceiveWindow          // Remote peer's receive window size
```

#### Static Factory Methods
```dart
static Future<UDXStream> createOutgoing(
  UDX udx,
  UDPSocket socket,
  int localId,
  int remoteId,
  String host,
  int port, {
  bool framed = false,
  int initialSeq = 0,
  int? initialCwnd,
  bool Function(UDPSocket socket, int port, String host)? firewall,
})
```
Creates a new outgoing stream to initiate a connection or open a new channel.

```dart
static UDXStream createIncoming(
  UDX udx,
  UDPSocket socket,
  int localId,
  int remoteId,
  String host,
  int port, {
  required ConnectionId destinationCid,
  required ConnectionId sourceCid,
  bool framed = false,
  int initialSeq = 0,
  int? initialCwnd,
  bool Function(UDPSocket socket, int port, String host)? firewall,
})
```
Creates a new incoming stream (used internally when accepting streams).

#### Methods
```dart
Stream<UDXEvent> on(String event)
```
Returns a stream for a given event type. Key events:
- `'data'`: Received data chunk (`Uint8List`)
- `'end'`: Remote peer finished writing
- `'error'`: Stream-level error
- `'close'`: Stream closed
- `'connect'`: Stream connected
- `'drain'`: Stream ready for more data
- `'ack'`: Packet acknowledged by peer
- `'send'`: Data sent to peer

#### StreamSink Interface
```dart
Future<void> add(Uint8List data)     // Send data
void addError(Object error, [StackTrace? stackTrace])  // Add error
Future<void> addStream(Stream<Uint8List> stream)       // Send stream data
Future<void> get done                // Completion future
Future<void> close()                 // Close stream gracefully
```

#### Stream Control
```dart
void setWindow(int newSize)
```
Updates the local receive window size and notifies the peer.

```dart
Future<void> reset(int errorCode)
```
Abruptly terminates the stream by sending a RESET_STREAM frame.

#### Data Streams
```dart
Stream<Uint8List> get data          // Incoming data stream
Stream<void> get end                // End event stream
Stream<void> get drain              // Drain event stream
Stream<int> get ack                 // ACK event stream
Stream<Uint8List> get send          // Send event stream
Stream<void> get closeEvents        // Close event stream
```

---

## 4. Flow Control & Congestion Management

### 4.1 Connection-Level Flow Control

Connection-level flow control prevents overwhelming the receiver's connection buffer across all streams.

#### Key Concepts
- **Connection Window**: Total bytes that can be in flight across all streams
- **MAX_DATA Frames**: Used to advertise window updates
- **Backpressure**: Automatic blocking when window is exhausted

#### Usage Example
```dart
// Monitor connection window updates
socket.on('remoteConnectionWindowUpdate').listen((event) {
  final newMaxData = event.data['maxData'];
  print('Remote connection window updated to: $newMaxData');
});

// Send connection window update
await socket.sendMaxDataFrame(2 * 1024 * 1024); // 2MB window
```

### 4.2 Stream-Level Flow Control

Stream-level flow control prevents head-of-line blocking between streams.

#### Key Concepts
- **Stream Window**: Bytes that can be in flight for a specific stream
- **WINDOW_UPDATE Frames**: Used to advertise stream window updates
- **Per-Stream Backpressure**: Each stream manages its own flow control

#### Usage Example
```dart
// Update stream receive window
stream.setWindow(128 * 1024); // 128KB window

// Monitor stream drain events
stream.drain.listen((_) {
  print('Stream ready for more data');
});
```

### 4.3 Congestion Control

UDX implements CUBIC congestion control with the following features:

#### CUBIC Algorithm Features
- **Slow Start**: Exponential growth until first loss
- **Congestion Avoidance**: Cubic function growth
- **Fast Recovery**: Quick recovery from single packet loss
- **Fast Retransmit**: Immediate retransmission on duplicate ACKs

#### Monitoring Congestion Control
```dart
// Monitor congestion window changes
print('CWND: ${stream.cwnd}, In-flight: ${stream.inflight}, RTT: ${stream.rtt}');

// Monitor ACK events for congestion control feedback
stream.ack.listen((ackedSequence) {
  print('Packet $ackedSequence acknowledged');
});
```

### 4.4 Packet Pacing

Packet pacing smooths out transmission to avoid bursts that can cause network congestion.

#### Features
- **Rate-based pacing**: Spreads packets over time based on estimated bandwidth
- **Burst limiting**: Prevents large bursts that can overwhelm network buffers
- **Adaptive pacing**: Adjusts to changing network conditions

---

## 5. Event System

UDX uses an event-driven architecture based on the `UDXEventEmitter` mixin. All major components emit events for various state changes and data events.

### 5.1 Socket Events

```dart
// Connection establishment
socket.on('connect').listen((_) => print('Socket connected'));

// New incoming streams
socket.on('stream').listen((event) {
  final stream = event.data as UDXStream;
  print('New stream: ${stream.id}');
});

// Path migration events
socket.on('pathUpdate').listen((event) {
  final host = event.data['host'];
  final port = event.data['port'];
  print('Path updated to $host:$port');
});

// Connection window updates
socket.on('remoteConnectionWindowUpdate').listen((event) {
  final maxData = event.data['maxData'];
  print('Remote connection window: $maxData');
});

// Stream limit updates
socket.on('remoteMaxStreamsUpdate').listen((event) {
  final maxStreams = event.data['maxStreams'];
  print('Remote max streams: $maxStreams');
});

// Socket closure
socket.on('close').listen((_) => print('Socket closed'));

// Socket errors
socket.on('error').listen((event) {
  print('Socket error: ${event.data}');
});
```

### 5.2 Stream Events

```dart
// Data reception
stream.data.listen((data) {
  print('Received ${data.length} bytes');
});

// Stream end
stream.end.listen((_) => print('Stream ended'));

// Stream ready for more data
stream.drain.listen((_) => print('Stream ready for more data'));

// Packet acknowledgments
stream.ack.listen((sequence) => print('Packet $sequence ACKed'));

// Data sent
stream.send.listen((data) => print('Sent ${data.length} bytes'));

// Stream closure
stream.closeEvents.listen((_) => print('Stream closed'));

// Stream errors
stream.on('error').listen((event) {
  print('Stream error: ${event.data}');
});
```

### 5.3 Multiplexer Events

```dart
// New connections
multiplexer.connections.listen((socket) {
  print('New connection from ${socket.remoteAddress}:${socket.remotePort}');
});
```

---

## 6. Error Handling

### 6.1 Error Types

#### StreamResetError
Thrown when a stream is reset by the remote peer.
```dart
stream.on('error').listen((event) {
  if (event.data is StreamResetError) {
    final error = event.data as StreamResetError;
    print('Stream reset with code: ${error.errorCode}');
  }
});
```

#### StreamLimitExceededError
Thrown when attempting to create more streams than the peer allows.
```dart
try {
  final stream = await UDXStream.createOutgoing(udx, socket, 1, 2, host, port);
} catch (e) {
  if (e is StreamLimitExceededError) {
    print('Too many streams: ${e.message}');
  }
}
```

#### StateError
Thrown for various invalid state operations.
```dart
try {
  await stream.add(data);
} catch (e) {
  if (e is StateError) {
    print('Invalid operation: ${e.message}');
  }
}
```

### 6.2 Error Recovery Strategies

#### Connection Recovery
```dart
socket.on('error').listen((event) async {
  print('Connection error: ${event.data}');
  
  // Attempt reconnection
  try {
    final newSocket = multiplexer.createSocket(udx, host, port);
    await newSocket.handshakeComplete;
    // Migrate streams to new socket if needed
  } catch (e) {
    print('Reconnection failed: $e');
  }
});
```

#### Stream Recovery
```dart
stream.on('error').listen((event) async {
  print('Stream error: ${event.data}');
  
  if (event.data is StreamResetError) {
    // Create new stream to replace reset one
    try {
      final newStream = await UDXStream.createOutgoing(
        udx, socket, newId, remoteId, host, port
      );
      // Resume operations on new stream
    } catch (e) {
      print('Stream recovery failed: $e');
    }
  }
});
```

---

## 7. Advanced Features

### 7.1 Path MTU Discovery (PMTUD)

PMTUD automatically discovers the optimal packet size for the network path.

#### Features
- **Automatic MTU discovery**: Finds largest packet size that doesn't fragment
- **Path change detection**: Adapts to new network paths
- **Probe packet management**: Sends test packets to discover MTU

#### Monitoring PMTUD
```dart
// MTU changes are reflected in the stream's mtu property
print('Current MTU: ${stream.mtu}');

// Monitor for MTU-related events (implementation-specific)
socket.on('mtuUpdate').listen((event) {
  print('MTU updated to: ${event.data}');
});
```

### 7.2 Connection Migration

Detailed connection migration implementation:

```dart
Future<void> migrateConnection(UDPSocket socket, String newInterface) async {
  // 1. Create new network socket
  final newRawSocket = await RawDatagramSocket.bind(
    InternetAddress(newInterface), 0
  );
  final newMux = UDXMultiplexer(newRawSocket);
  
  // 2. Remove from old multiplexer
  final oldMux = socket.multiplexer;
  oldMux.removeSocket(socket.cids.localCid);
  
  // 3. Add to new multiplexer
  newMux.addSocket(socket);
  socket.multiplexer = newMux;
  
  // 4. Send probe packet to trigger path validation
  // This happens automatically when the socket sends its next packet
  
  // 5. Wait for path validation
  await socket.on('pathUpdate').first;
  
  // 6. Clean up old multiplexer
  oldMux.close();
  
  print('Migration completed successfully');
}
```

### 7.3 Stream Concurrency Management

```dart
// Check stream limits before creating
if (socket.canCreateNewStream()) {
  final stream = await UDXStream.createOutgoing(udx, socket, id, remoteId, host, port);
} else {
  print('Cannot create stream: limit reached');
}

// Monitor stream limit updates
socket.on('remoteMaxStreamsUpdate').listen((event) {
  final newLimit = event.data['maxStreams'];
  print('Can now create up to $newLimit concurrent streams');
});

// Update local stream limit
socket.setLocalMaxStreamsForTest(200); // For testing only
await socket.sendMaxStreamsFrame();
```

---

## 8. Usage Examples

### 8.1 File Transfer Server

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/udx.dart';

class FileTransferServer {
  late UDXMultiplexer multiplexer;
  
  Future<void> start(int port) async {
    final udx = UDX();
    final serverSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, port
    );
    multiplexer = UDXMultiplexer(serverSocket);
    
    print('File server listening on port $port');
    
    multiplexer.connections.listen((socket) {
      print('Client connected: ${socket.remoteAddress}:${socket.remotePort}');
      
      socket.on('stream').listen((event) {
        final stream = event.data as UDXStream;
        _handleFileRequest(stream);
      });
      
      socket.on('error').listen((event) {
        print('Socket error: ${event.data}');
      });
    });
  }
  
  void _handleFileRequest(UDXStream stream) async {
    try {
      // Read filename from first packet
      final filenameData = await stream.data.first;
      final filename = String.fromCharCodes(filenameData);
      
      print('File request: $filename');
      
      final file = File(filename);
      if (!await file.exists()) {
        await stream.reset(404); // File not found
        return;
      }
      
      // Send file size first
      final fileSize = await file.length();
      final sizeBytes = Uint8List(8);
      sizeBytes.buffer.asByteData().setUint64(0, fileSize);
      await stream.add(sizeBytes);
      
      // Send file contents
      final fileStream = file.openRead();
      await stream.addStream(fileStream);
      await stream.close();
      
      print('File transfer completed: $filename');
      
    } catch (e) {
      print('File transfer error: $e');
      await stream.reset(500); // Internal server error
    }
  }
  
  void stop() {
    multiplexer.close();
  }
}
```

### 8.2 File Transfer Client

```dart
class FileTransferClient {
  late UDXMultiplexer multiplexer;
  late UDPSocket socket;
  
  Future<void> connect(String host, int port) async {
    final udx = UDX();
    final clientSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, 0
    );
    multiplexer = UDXMultiplexer(clientSocket);
    socket = multiplexer.createSocket(udx, host, port);
    
    await socket.handshakeComplete;
    print('Connected to server');
  }
  
  Future<void> downloadFile(String filename, String localPath) async {
    final stream = await UDXStream.createOutgoing(
      UDX(), socket, 1, 2, socket.remoteAddress.address, socket.remotePort
    );
    
    try {
      // Send filename request
      await stream.add(Uint8List.fromList(filename.codeUnits));
      
      // Receive file size
      final sizeData = await stream.data.first;
      final fileSize = sizeData.buffer.asByteData().getUint64(0);
      print('Downloading file: $filename (${fileSize} bytes)');
      
      // Receive file contents
      final output = File(localPath).openWrite();
      int bytesReceived = 0;
      
      await for (final chunk in stream.data) {
        await output.add(chunk);
        bytesReceived += chunk.length;
        
        final progress = (bytesReceived / fileSize * 100).toStringAsFixed(1);
        print('Progress: $progress% ($bytesReceived/$fileSize bytes)');
        
        if (bytesReceived >= fileSize) break;
      }
      
      await output.close();
      print('Download completed: $localPath');
      
    } catch (e) {
      print('Download error: $e');
    } finally {
      await stream.close();
    }
  }
  
  void disconnect() {
    socket.close();
    multiplexer.close();
  }
}
```

### 8.3 Chat Application

```dart
class ChatServer {
  late UDXMultiplexer multiplexer;
  final Set<UDXStream> clients = {};
  
  Future<void> start(int port) async {
    final udx = UDX();
    final serverSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, port
    );
    multiplexer = UDXMultiplexer(serverSocket);
    
    print('Chat server listening on port $port');
    
    multiplexer.connections.listen((socket) {
      socket.on('stream').listen((event) {
        final stream = event.data as UDXStream;
        _handleChatClient(stream);
      });
    });
  }
  
  void _handleChatClient(UDXStream stream) {
    clients.add(stream);
    print('Client joined chat: ${clients.length} total clients');
    
    // Broadcast join message
    _broadcast('User joined the chat', exclude: stream);
    
    stream.data.listen((data) {
      final message = String.fromCharCodes(data);
      print('Message: $message');
      _broadcast(message, exclude: stream);
    });
    
    stream.closeEvents.listen((_) {
      clients.remove(stream);
      print('Client left chat: ${clients.length} total clients');
      _broadcast('User left the chat', exclude: stream);
    });
    
    stream.on('error').listen((event) {
      print('Client error: ${event.data}');
      clients.remove(stream);
    });
  }
  
  void _broadcast(String message, {UDXStream? exclude}) {
    final data = Uint8List.fromList(message.codeUnits);
    for (final client in clients) {
      if (client != exclude && client.connected) {
        client.add(data).catchError((e) {
          print('Broadcast error: $e');
          clients.remove(client);
        });
      }
    }
  }
}
```

### 8.4 Performance Monitoring

```dart
class PerformanceMonitor {
  final UDXStream stream;
  Timer? _timer;
  int _lastBytesSent = 0;
  int _lastBytesReceived = 0;
  DateTime _lastCheck = DateTime.now();
  
  PerformanceMonitor(this.stream);
  
  void start() {
    _timer = Timer.periodic(Duration(seconds: 1), (_) => _updateStats());
    
    // Monitor congestion control events
    stream.ack.listen((sequence) {
      print('ACK received for packet $sequence');
    });
    
    stream.on('error').listen((event) {
      print('Stream error: ${event.data}');
    });
  }
  
  void _updateStats() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastCheck).inMilliseconds / 1000.0;
    
    // Calculate throughput (this would need actual byte counters)
    final sendRate = 0; // (_currentBytesSent - _lastBytesSent) / elapsed;
    final recvRate = 0; // (_currentBytesReceived - _lastBytesReceived) / elapsed;
    
    print('Performance Stats:');
    print('  RTT: ${stream.rtt.inMilliseconds}ms');
    print('  CWND: ${stream.cwnd} bytes');
    print('  In-flight: ${stream.inflight} bytes');
    print('  Send rate: ${(sendRate / 1024).toStringAsFixed(2)} KB/s');
    print('  Recv rate: ${(recvRate / 1024).toStringAsFixed(2)} KB/s');
    print('  Stream window: ${stream.receiveWindow} bytes');
    print('  Remote window: ${stream.remoteReceiveWindow} bytes');
    
    _lastCheck = now;
  }
  
  void stop() {
    _timer?.cancel();
  }
}
```

---

## 9. Performance Tuning

### 9.1 Buffer Size Optimization

```dart
// Optimize socket buffers for high-throughput applications
socket.setRecvBufferSize(2 * 1024 * 1024); // 2MB receive buffer
socket.setSendBufferSize(2 * 1024 * 1024); // 2MB send buffer

// Optimize stream windows for high-bandwidth networks
stream.setWindow(1024 * 1024); // 1MB stream window
```

### 9.2 Congestion Control Tuning

```dart
// Create stream with custom initial congestion window
final stream = await UDXStream.createOutgoing(
  udx, socket, localId, remoteId, host, port,
  initialCwnd: 64 * 1024, // 64KB initial window
);
```

### 9.3 Connection-Level Tuning

```dart
// Increase connection-level flow control window for multiple streams
await socket.sendMaxDataFrame(10 * 1024 * 1024); // 10MB connection window

// Increase concurrent stream limit for multiplexed applications
await socket.sendMaxStreamsFrame(); // Uses default limit
```

### 9.4 MTU Optimization

```dart
// Monitor MTU for optimal packet sizing
print('Current MTU: ${stream.mtu}');

// MTU affects maximum payload size per packet
final maxPayload = stream.mtu - 16; // Account for headers
print('Max payload per packet: $maxPayload bytes');
```

---

## 10. Troubleshooting

### 10.1 Common Issues

#### Connection Timeouts
```dart
// Add timeout handling for connection establishment
try {
  await socket.handshakeComplete.timeout(Duration(seconds: 10));
} catch (e) {
  if (e is TimeoutException) {
    print('Connection timeout - check network connectivity');
  }
}
```

#### Stream Backpressure
```dart
// Handle backpressure when sending large amounts of data
Future<void> sendLargeData(UDXStream stream, Uint8List data) async {
  const chunkSize = 64 * 1024; // 64KB chunks
  
  for (int i = 0; i < data.length; i += chunkSize) {
    final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
    final chunk = data.sublist(i, end);
    
    try {
      await stream.add(chunk);
    } catch (e) {
      if (e is StateError && e.message.contains('backpressure')) {
        // Wait for drain event and retry
        await stream.drain.first;
        await stream.add(chunk);
      } else {
        rethrow;
      }
    }
  }
}
```

#### Memory Issues
```dart
// Monitor memory usage for long-running connections
void monitorMemory(UDPSocket socket) {
  Timer.periodic(Duration(minutes: 5), (_) {
    print('Active streams: ${socket.busy ? "Yes" : "No"}');
    print('Socket state: ${socket.closing ? "Closing" : "Active"}');
    
    // Force garbage collection if needed
    if (socket.idle) {
      // Consider closing idle connections
      print('Socket is idle, consider cleanup');
    }
  });
}
```

### 10.2 Debugging Tools

#### Packet Tracing
```dart
// Enable detailed packet logging (for development only)
class PacketTracer {
  static void traceSocket(UDPSocket socket) {
    socket.on('connect').listen((_) {
      print('[TRACE] Socket connected: ${socket.remoteAddress}:${socket.remotePort}');
    });
    
    socket.on('pathUpdate').listen((event) {
      print('[TRACE] Path updated: ${event.data}');
    });
    
    socket.on('remoteConnectionWindowUpdate').listen((event) {
      print('[TRACE] Connection window update: ${event.data}');
    });
  }
  
  static void traceStream(UDXStream stream) {
    stream.ack.listen((seq) {
      print('[TRACE] ACK received: seq=$seq, cwnd=${stream.cwnd}, rtt=${stream.rtt.inMilliseconds}ms');
    });
    
    stream.send.listen((data) {
      print('[TRACE] Data sent: ${data.length} bytes, inflight=${stream.inflight}');
    });
    
    stream.data.listen((data) {
      print('[TRACE] Data received: ${data.length} bytes');
    });
  }
}
```

#### Performance Profiling
```dart
class UDXProfiler {
  final Map<String, DateTime> _timestamps = {};
  final Map<String, int> _counters = {};
  
  void startTimer(String name) {
    _timestamps[name] = DateTime.now();
  }
  
  void endTimer(String name) {
    final start = _timestamps[name];
    if (start != null) {
      final duration = DateTime.now().difference(start);
      print('[PROFILE] $name: ${duration.inMicroseconds}μs');
    }
  }
  
  void incrementCounter(String name) {
    _counters[name] = (_counters[name] ?? 0) + 1;
  }
  
  void printStats() {
    print('[PROFILE] Counters:');
    _counters.forEach((name, count) {
      print('  $name: $count');
    });
  }
}
```

### 10.3 Network Diagnostics

#### Path Validation Testing
```dart
Future<bool> testPathConnectivity(String host, int port) async {
  try {
    final udx = UDX();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final mux = UDXMultiplexer(socket);
    final udpSocket = mux.createSocket(udx, host, port);
    
    // Attempt connection with timeout
    await udpSocket.handshakeComplete.timeout(Duration(seconds: 5));
    
    udpSocket.close();
    mux.close();
    return true;
  } catch (e) {
    print('Path connectivity test failed: $e');
    return false;
  }
}
```

#### MTU Discovery Testing
```dart
Future<int> discoverPathMTU(String host, int port) async {
  // This would integrate with the PMTUD controller
  // For now, return default MTU
  return 1400;
}
```

---

## 11. Best Practices

### 11.1 Connection Management

#### Resource Cleanup
```dart
class ConnectionManager {
  final Map<String, UDPSocket> _connections = {};
  final UDXMultiplexer multiplexer;
  
  ConnectionManager(this.multiplexer);
  
  Future<UDPSocket> getConnection(String host, int port) async {
    final key = '$host:$port';
    
    if (_connections.containsKey(key)) {
      final existing = _connections[key]!;
      if (!existing.closing) {
        return existing;
      } else {
        _connections.remove(key);
      }
    }
    
    final socket = multiplexer.createSocket(UDX(), host, port);
    await socket.handshakeComplete;
    
    // Set up cleanup on close
    socket.on('close').listen((_) {
      _connections.remove(key);
    });
    
    _connections[key] = socket;
    return socket;
  }
  
  void closeAll() {
    for (final socket in _connections.values) {
      socket.close();
    }
    _connections.clear();
  }
}
```

#### Connection Pooling
```dart
class UDXConnectionPool {
  final int maxConnections;
  final Duration idleTimeout;
  final Map<String, List<UDPSocket>> _pool = {};
  final Map<UDPSocket, Timer> _idleTimers = {};
  
  UDXConnectionPool({
    this.maxConnections = 10,
    this.idleTimeout = const Duration(minutes: 5),
  });
  
  Future<UDPSocket> acquire(UDXMultiplexer mux, String host, int port) async {
    final key = '$host:$port';
    final available = _pool[key];
    
    if (available != null && available.isNotEmpty) {
      final socket = available.removeLast();
      _idleTimers[socket]?.cancel();
      _idleTimers.remove(socket);
      return socket;
    }
    
    // Create new connection
    final socket = mux.createSocket(UDX(), host, port);
    await socket.handshakeComplete;
    return socket;
  }
  
  void release(UDPSocket socket) {
    if (socket.closing) return;
    
    final key = '${socket.remoteAddress.address}:${socket.remotePort}';
    final pool = _pool.putIfAbsent(key, () => <UDPSocket>[]);
    
    if (pool.length < maxConnections) {
      pool.add(socket);
      
      // Set idle timeout
      _idleTimers[socket] = Timer(idleTimeout, () {
        pool.remove(socket);
        _idleTimers.remove(socket);
        socket.close();
      });
    } else {
      socket.close();
    }
  }
}
```

### 11.2 Error Handling Patterns

#### Retry Logic
```dart
class RetryableOperation {
  static Future<T> withRetry<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 1),
    bool Function(dynamic error)? shouldRetry,
  }) async {
    int attempts = 0;
    
    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;
        
        if (attempts >= maxRetries || (shouldRetry != null && !shouldRetry(e))) {
          rethrow;
        }
        
        await Future.delayed(delay * attempts); // Exponential backoff
      }
    }
    
    throw StateError('Max retries exceeded');
  }
}

// Usage example
final stream = await RetryableOperation.withRetry(
  () => UDXStream.createOutgoing(udx, socket, 1, 2, host, port),
  maxRetries: 3,
  shouldRetry: (e) => e is! StreamLimitExceededError,
);
```

#### Circuit Breaker Pattern
```dart
class CircuitBreaker {
  final int failureThreshold;
  final Duration timeout;
  
  int _failureCount = 0;
  DateTime? _lastFailureTime;
  bool _isOpen = false;
  
  CircuitBreaker({
    this.failureThreshold = 5,
    this.timeout = const Duration(minutes: 1),
  });
  
  Future<T> execute<T>(Future<T> Function() operation) async {
    if (_isOpen) {
      if (_lastFailureTime != null &&
          DateTime.now().difference(_lastFailureTime!) > timeout) {
        _isOpen = false;
        _failureCount = 0;
      } else {
        throw StateError('Circuit breaker is open');
      }
    }
    
    try {
      final result = await operation();
      _failureCount = 0;
      return result;
    } catch (e) {
      _failureCount++;
      _lastFailureTime = DateTime.now();
      
      if (_failureCount >= failureThreshold) {
        _isOpen = true;
      }
      
      rethrow;
    }
  }
}
```

### 11.3 Performance Optimization

#### Batch Operations
```dart
class BatchSender {
  final UDXStream stream;
  final List<Uint8List> _buffer = [];
  final int maxBatchSize;
  Timer? _flushTimer;
  
  BatchSender(this.stream, {this.maxBatchSize = 10});
  
  void send(Uint8List data) {
    _buffer.add(data);
    
    if (_buffer.length >= maxBatchSize) {
      _flush();
    } else {
      _flushTimer?.cancel();
      _flushTimer = Timer(Duration(milliseconds: 10), _flush);
    }
  }
  
  void _flush() {
    if (_buffer.isEmpty) return;
    
    // Combine all buffered data
    final totalLength = _buffer.fold<int>(0, (sum, data) => sum + data.length);
    final combined = Uint8List(totalLength);
    
    int offset = 0;
    for (final data in _buffer) {
      combined.setRange(offset, offset + data.length, data);
      offset += data.length;
    }
    
    stream.add(combined);
    _buffer.clear();
    _flushTimer?.cancel();
  }
  
  void dispose() {
    _flush();
    _flushTimer?.cancel();
  }
}
```

#### Memory Management
```dart
class StreamManager {
  final Map<int, UDXStream> _streams = {};
  final int maxStreams;
  
  StreamManager({this.maxStreams = 100});
  
  void addStream(UDXStream stream) {
    if (_streams.length >= maxStreams) {
      // Close oldest idle stream
      final oldestIdle = _streams.values
          .where((s) => s.connected && !s.busy)
          .firstOrNull;
      
      if (oldestIdle != null) {
        oldestIdle.close();
        _streams.remove(oldestIdle.id);
      }
    }
    
    _streams[stream.id] = stream;
    
    stream.closeEvents.listen((_) {
      _streams.remove(stream.id);
    });
  }
  
  void closeAll() {
    for (final stream in _streams.values) {
      stream.close();
    }
    _streams.clear();
  }
}
```

### 11.4 Security Considerations

#### Input Validation
```dart
class SecureUDXStream {
  final UDXStream _stream;
  final int maxMessageSize;
  
  SecureUDXStream(this._stream, {this.maxMessageSize = 1024 * 1024});
  
  Stream<Uint8List> get data {
    return _stream.data.where((data) {
      if (data.length > maxMessageSize) {
        print('Warning: Oversized message rejected (${data.length} bytes)');
        return false;
      }
      return true;
    });
  }
  
  Future<void> add(Uint8List data) async {
    if (data.length > maxMessageSize) {
      throw ArgumentError('Message too large: ${data.length} bytes');
    }
    await _stream.add(data);
  }
}
```

#### Rate Limiting
```dart
class RateLimiter {
  final int maxRequests;
  final Duration window;
  final Queue<DateTime> _requests = Queue();
  
  RateLimiter({
    this.maxRequests = 100,
    this.window = const Duration(minutes: 1),
  });
  
  bool allowRequest() {
    final now = DateTime.now();
    final cutoff = now.subtract(window);
    
    // Remove old requests
    while (_requests.isNotEmpty && _requests.first.isBefore(cutoff)) {
      _requests.removeFirst();
    }
    
    if (_requests.length >= maxRequests) {
      return false;
    }
    
    _requests.add(now);
    return true;
  }
}
```

---

## Conclusion

This enhanced UDX API documentation provides comprehensive coverage of the library's capabilities, from basic usage to advanced features like connection migration and performance tuning. The library offers a powerful foundation for building high-performance, reliable UDP-based applications with modern networking features.

### Key Takeaways

1. **Layered Architecture**: The multiplexer → socket → stream hierarchy provides clear separation of concerns
2. **Advanced Features**: CUBIC congestion control, flow control, and connection migration enable robust applications
3. **Event-Driven Design**: Rich event system allows for responsive, real-time applications
4. **Performance Focus**: Built-in optimizations like packet pacing and PMTUD maximize network efficiency
5. **Production Ready**: Comprehensive error handling and debugging tools support production deployments

For additional support and examples, refer to the test files in the `test/` directory, which demonstrate many of these concepts in practice.
