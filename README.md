# Dart UDX

A Dart implementation of UDX - reliable, multiplexed, and congestion-controlled streams over UDP.

[![Pub Version](https://img.shields.io/pub/v/dart_udx)](https://pub.dev/packages/dart_udx)
[![Dart SDK](https://img.shields.io/badge/Dart-%3E%3D3.0.0-blue)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

UDX is a QUIC-inspired, UDP-based transport protocol that provides reliable, ordered delivery with advanced networking features. This Dart implementation offers the core building blocks for creating high-performance, connection-oriented communication over UDP.

## Key Features

- **Reliable & Ordered Delivery** - TCP-like reliability over UDP
- **CUBIC Congestion Control** - Optimal throughput with adaptive bandwidth utilization  
- **Multi-layer Flow Control** - Both connection and stream-level flow control
- **Connection Migration** - Seamless network path changes for mobile applications
- **Path MTU Discovery** - Automatic optimization of packet sizes
- **Packet Pacing** - Smooth network utilization to prevent bursts
- **Stream Multiplexing** - Multiple concurrent streams per connection
- **Event-Driven Architecture** - Responsive, asynchronous I/O

### What's New in v2.0 (Enhanced QUIC Compliance)

- **Variable-Length Connection IDs** - Flexible CID sizes (0-20 bytes) for improved privacy
- **Version Negotiation** - Automatic protocol version negotiation
- **Graceful Connection Termination** - CONNECTION_CLOSE frames with error details
- **Unidirectional Streams** - Half-duplex streams for optimized data flow
- **STOP_SENDING Frame** - Receiver-initiated stream termination
- **Flow Control Signaling** - BLOCKED frames for better congestion visibility
- **Stream Priorities** - Priority-based stream scheduling
- **Anti-Amplification Protection** - Built-in DDoS mitigation per RFC 9000
- **Stateless Reset** - Connection recovery without state
- **ECN Support** - Infrastructure for Explicit Congestion Notification
- **Improved RTT Estimation** - RFC 9002 compliant ACK delay handling

See [CHANGELOG.md](CHANGELOG.md) for full details and migration guide.

## Installation

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  dart_udx: ^0.3.0
```

Then run:

```bash
dart pub get
```

## Quick Start

### Basic Server

```dart
import 'dart:io';
import 'package:dart_udx/udx.dart';

void main() async {
  final udx = UDX();
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8080);
  final multiplexer = UDXMultiplexer(socket);

  print('UDX server listening on port 8080');

  multiplexer.connections.listen((connection) {
    print('New connection from ${connection.remoteAddress}');
    
    connection.on('stream').listen((event) {
      final stream = event.data as UDXStream;
      
      stream.data.listen((data) {
        print('Received: ${String.fromCharCodes(data)}');
        stream.add(data); // Echo back
      });
    });
  });
}
```

### Basic Client

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/udx.dart';

void main() async {
  final udx = UDX();
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final multiplexer = UDXMultiplexer(socket);
  
  final connection = multiplexer.createSocket(udx, '127.0.0.1', 8080);
  await connection.handshakeComplete;

  final stream = await UDXStream.createOutgoing(
    udx, connection, 1, 2, '127.0.0.1', 8080
  );

  // Send data
  final message = 'Hello, UDX!';
  await stream.add(Uint8List.fromList(message.codeUnits));

  // Receive echo
  stream.data.listen((data) {
    print('Received: ${String.fromCharCodes(data)}');
    stream.close();
    connection.close();
  });
}
```

## Architecture

UDX follows a layered architecture for maximum flexibility:

- **`UDXMultiplexer`** - Manages I/O for multiple connections over a single UDP socket
- **`UDPSocket`** - Represents a single logical connection with handshake and flow control  
- **`UDXStream`** - Provides reliable, ordered data streams with congestion control

This design enables advanced features like connection migration, where connections can seamlessly move between network interfaces.

## Advanced Features

- **Connection Migration** - Move connections between network interfaces without dropping
- **Flow Control** - Prevent overwhelming receivers at both connection and stream levels
- **Congestion Control** - CUBIC algorithm with slow start, congestion avoidance, and fast recovery
- **Error Recovery** - Automatic retransmission and duplicate detection
- **Performance Monitoring** - Built-in RTT, throughput, and congestion window metrics

## Documentation

For detailed API documentation, advanced usage examples, and best practices, see the [Developer Guide](DEVELOPER_GUIDE.md).

## Performance

UDX is designed for high-performance applications:

- Zero-copy packet processing where possible
- Efficient memory management with configurable buffers
- Packet pacing to maximize network utilization
- Adaptive MTU discovery for optimal packet sizes

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## License

This project is licensed under the MIT License - see below for details.

```
MIT License

Copyright (c) 2025 - Stephan M. February

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Acknowledgments

This implementation is inspired by the original [UDX protocol](https://github.com/holepunchto/udx) and incorporates concepts from QUIC and modern transport protocol design. 