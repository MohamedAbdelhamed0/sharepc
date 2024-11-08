import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;

class FileTransferPage extends StatefulWidget {
  @override
  _FileTransferPageState createState() => _FileTransferPageState();
}

class _FileTransferPageState extends State<FileTransferPage> {
  IOWebSocketChannel? _channel;
  String _status = 'Idle';
  final TextEditingController _ipController = TextEditingController();
  bool _isLoading = false; // Indicates if a file transfer is in progress
  double _progress = 0.0; // Progress value between 0.0 and 1.0

  DateTime? _transferStartTime;
  int _totalBytesToTransfer = 0;
  int _bytesTransferred = 0;
  double _transferSpeed = 0.0; // in bytes per second
  String _estimatedTimeRemaining = '';

  @override
  void dispose() {
    _channel?.sink.close(status.goingAway);
    super.dispose();
  }

  void _connect() {
    final ip = _ipController.text;
    _channel = IOWebSocketChannel.connect('ws://$ip:8765');
    setState(() {
      _status = 'Connected to $ip';
    });

    _channel!.stream.listen((message) async {
      if (message is String) {
        Map<String, dynamic> data = jsonDecode(message);
        if (data['type'] == 'metadata') {
          // Start receiving a new file
          await _handleIncomingFile(data);
        } else if (data['type'] == 'command') {
          if (data['command'] == 'send_files') {
            _sendFiles();
          }
        } else {
          setState(() {
            _status = 'Received unknown message type.';
          });
        }
      } else {
        setState(() {
          _status = 'Received unexpected binary data.';
        });
      }
    }, onDone: () {
      setState(() {
        _status = 'Connection closed.';
        _isLoading = false;
        _progress = 0.0;
      });
    }, onError: (error) {
      setState(() {
        _status = 'Error: $error';
        _isLoading = false;
        _progress = 0.0;
      });
    });
  }

  Future<void> _handleIncomingFile(Map<String, dynamic> metadata) async {
    String filename = metadata['filename'];
    int filesize = metadata['filesize'];

    // Request storage permissions
    var permissionStatus = await Permission.storage.request();

    if (!permissionStatus.isGranted) {
      setState(() {
        _status = 'Storage permission denied.';
      });
      return;
    }

    Directory? downloadsDirectory =
        await getExternalStorageDirectory(); // Android only

    if (downloadsDirectory == null) {
      setState(() {
        _status = 'Failed to get downloads directory.';
      });
      return;
    }

    String filePath = '${downloadsDirectory.path}/$filename';
    File file = File(filePath);
    IOSink fileSink = file.openWrite();
    int bytesReceived = 0;

    // Initialize transfer statistics
    _transferStartTime = DateTime.now();
    _totalBytesToTransfer = filesize;
    _bytesTransferred = 0;
    _transferSpeed = 0.0;
    _estimatedTimeRemaining = '';

    setState(() {
      _isLoading = true;
      _status = 'Receiving $filename...';
      _progress = 0.0;
    });

    StreamSubscription? subscription;
    subscription = _channel!.stream.listen((message) async {
      if (message is String) {
        Map<String, dynamic> data = jsonDecode(message);
        if (data['type'] == 'data') {
          // Receive a chunk of data
          List<int> chunk = base64Decode(data['content']);
          fileSink.add(chunk);
          bytesReceived += chunk.length;
          _bytesTransferred = bytesReceived;

          // Calculate progress and update UI
          setState(() {
            _progress = bytesReceived / filesize;

            // Calculate transfer speed and estimated time remaining
            Duration elapsed = DateTime.now().difference(_transferStartTime!);
            if (elapsed.inSeconds > 0) {
              _transferSpeed = _bytesTransferred /
                  elapsed.inSeconds.toDouble(); // bytes per second

              int bytesRemaining = _totalBytesToTransfer - _bytesTransferred;
              double timeRemainingSeconds = bytesRemaining / _transferSpeed;
              _estimatedTimeRemaining = _formatDuration(
                  Duration(seconds: timeRemainingSeconds.round()));
            } else {
              _transferSpeed = 0.0;
              _estimatedTimeRemaining = 'Calculating...';
            }
          });
        } else if (data['type'] == 'end') {
          // Finished receiving the file
          await fileSink.close();
          setState(() {
            _status = 'File $filename received and saved.';
            _isLoading = false;
            _progress = 0.0;
            _transferSpeed = 0.0;
            _estimatedTimeRemaining = '';
          });
          // Notify the user where the file is saved
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File saved to $filePath')),
          );
          // Cancel the subscription to prevent listening further
          subscription?.cancel();
        }
      }
    });
  }

  void _sendFiles() async {
    setState(() {
      _isLoading = true;
      _status = 'Selecting files to send...';
    });

    List<File>? files = await _pickFilesToSend();
    if (files != null && files.isNotEmpty) {
      for (File file in files) {
        String filename = file.path.split('/').last;
        int filesize = await file.length();

        // Initialize transfer statistics
        _transferStartTime = DateTime.now();
        _totalBytesToTransfer = filesize;
        _bytesTransferred = 0;
        _transferSpeed = 0.0;
        _estimatedTimeRemaining = '';

        // Send file metadata
        Map<String, dynamic> metadata = {
          'type': 'metadata',
          'filename': filename,
          'filesize': filesize,
        };
        String metadataJson = jsonEncode(metadata);
        _channel?.sink.add(metadataJson);

        setState(() {
          _status = 'Sending $filename...';
          _progress = 0.0;
        });

        // Send file content in chunks
        Stream<List<int>> stream = file.openRead();
        int bytesSent = 0;
        await for (List<int> chunk in stream) {
          String chunkBase64 = base64Encode(chunk);
          Map<String, dynamic> dataMessage = {
            'type': 'data',
            'content': chunkBase64,
          };
          String dataJson = jsonEncode(dataMessage);
          _channel?.sink.add(dataJson);

          bytesSent += chunk.length;
          _bytesTransferred = bytesSent;

          // Calculate progress and update UI
          setState(() {
            _progress = bytesSent / filesize;

            // Calculate transfer speed and estimated time remaining
            Duration elapsed = DateTime.now().difference(_transferStartTime!);
            if (elapsed.inSeconds > 0) {
              _transferSpeed = _bytesTransferred /
                  elapsed.inSeconds.toDouble(); // bytes per second

              int bytesRemaining = _totalBytesToTransfer - _bytesTransferred;
              double timeRemainingSeconds = bytesRemaining / _transferSpeed;
              _estimatedTimeRemaining = _formatDuration(
                  Duration(seconds: timeRemainingSeconds.round()));
            } else {
              _transferSpeed = 0.0;
              _estimatedTimeRemaining = 'Calculating...';
            }
          });
        }

        // Send end message
        Map<String, dynamic> endMessage = {'type': 'end'};
        String endJson = jsonEncode(endMessage);
        _channel?.sink.add(endJson);

        setState(() {
          _status = 'File $filename sent.';
          _progress = 0.0;
          _transferSpeed = 0.0;
          _estimatedTimeRemaining = '';
        });
      }

      setState(() {
        _isLoading = false;
        _status = 'All files sent.';
      });
    } else {
      setState(() {
        _status = 'File selection canceled.';
        _isLoading = false;
      });
    }
  }

  Future<List<File>?> _pickFilesToSend() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.paths.isNotEmpty) {
      return result.paths.map((path) => File(path!)).toList();
    } else {
      return null;
    }
  }

  void _requestFilesFromServer() {
    setState(() {
      _isLoading = true;
      _status = 'Requesting files from server...';
    });
    Map<String, dynamic> command = {
      'type': 'command',
      'command': 'send_files',
    };
    String commandJson = jsonEncode(command);
    _channel?.sink.add(commandJson);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
    } else {
      return '$twoDigitMinutes:$twoDigitSeconds';
    }
  }

  String _formatSpeed(double speedBytesPerSecond) {
    if (speedBytesPerSecond >= 1024 * 1024) {
      // Convert to MB/s
      double speedMBs = speedBytesPerSecond / (1024 * 1024);
      return '${speedMBs.toStringAsFixed(2)} MB/s';
    } else if (speedBytesPerSecond >= 1024) {
      // Convert to KB/s
      double speedKBs = speedBytesPerSecond / 1024;
      return '${speedKBs.toStringAsFixed(2)} KB/s';
    } else {
      return '${speedBytesPerSecond.toStringAsFixed(2)} B/s';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('File Transfer'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // IP Address Input and Connect Button
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ipController,
                    decoration: InputDecoration(
                      labelText: 'Server IP Address',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _connect,
                  child: Text('Connect'),
                ),
              ],
            ),
            SizedBox(height: 20),
            // Send and Receive Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _channel == null ? null : _sendFiles,
                  icon: Icon(Icons.upload_file),
                  label: Text('Send Files'),
                ),
                ElevatedButton.icon(
                  onPressed: _channel == null ? null : _requestFilesFromServer,
                  icon: Icon(Icons.download),
                  label: Text('Receive Files'),
                ),
              ],
            ),
            SizedBox(height: 20),
            // Progress Indicator
            if (_isLoading)
              Column(
                children: [
                  LinearProgressIndicator(value: _progress),
                  SizedBox(height: 10),
                  Text('${(_progress * 100).toStringAsFixed(2)}%'),
                  SizedBox(height: 10),
                  Text('Speed: ${_formatSpeed(_transferSpeed)}'),
                  Text('Time remaining: $_estimatedTimeRemaining'),
                ],
              ),
            SizedBox(height: 20),
            // Status Message
            Text(
              'Status: $_status',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
