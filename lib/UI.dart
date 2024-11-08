// File: file_transfer_page.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart'; // For file hashing
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'; // For directory paths
import 'package:permission_handler/permission_handler.dart'; // For permissions on Android
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
  bool _isLoading = false;

  DateTime? _transferStartTime;
  int _totalBytesToTransfer = 0;
  int _bytesTransferred = 0;
  double _transferSpeed = 0.0;
  String _estimatedTimeRemaining = '';

  List<FileTransferInfo> _selectedFiles =
      []; // Updated to store FileTransferInfo

  // File receiving variables
  File? _receivingFile;
  IOSink? _fileSink;
  int _bytesReceived = 0;
  String? _receivingFilename;
  int _receivingFilesize = 0;
  Digest? _receivedFileHash; // For file hash verification
  double _receiveProgress = 0.0;

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
      try {
        if (message is String) {
          Map<String, dynamic> data = jsonDecode(message);

          if (data['type'] == 'metadata') {
            // Start receiving a new file
            await _prepareToReceiveFile(data);
          } else if (data['type'] == 'data' && _fileSink != null) {
            // Receive a chunk of data
            List<int> chunk = base64Decode(data['content']);
            _fileSink!.add(chunk);
            _bytesReceived += chunk.length;
            _bytesTransferred = _bytesReceived;

            // Update hash
            _receivedFileHash ??= sha256.convert([]);
            _receivedFileHash =
                sha256.convert([..._receivedFileHash!.bytes, ...chunk]);

            // Update progress and UI
            _updateReceiveProgress();
          } else if (data['type'] == 'end' && _fileSink != null) {
            // Finished receiving the file
            await _fileSink!.close();
            // Wait for hash verification
            setState(() {
              _status = 'Waiting for file hash verification...';
            });
          } else if (data['type'] == 'hash') {
            // Received file hash from server
            String serverHash = data['hash'];
            String clientHash = _receivedFileHash.toString();
            if (serverHash == clientHash) {
              setState(() {
                _status =
                    'File $_receivingFilename received successfully with matching hash.';
                _isLoading = false;
                _receiveProgress = 0.0;
                _transferSpeed = 0.0;
                _estimatedTimeRemaining = '';
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('File saved to ${_receivingFile!.path}')),
              );
            } else {
              setState(() {
                _status = 'File hash mismatch. The file may be corrupted.';
                _isLoading = false;
                _receiveProgress = 0.0;
                _transferSpeed = 0.0;
                _estimatedTimeRemaining = '';
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content:
                        Text('File hash mismatch. The file may be corrupted.')),
              );
              // Optionally delete the corrupted file
              _receivingFile?.delete();
            }
            // Reset the file receiving variables
            _resetFileReception();
          } else if (data['type'] == 'cancel') {
            // Server canceled the transfer
            setState(() {
              _status = 'Server canceled the file transfer.';
              _isLoading = false;
              _receiveProgress = 0.0;
            });
            // Clean up any partially received file
            await _fileSink?.close();
            _receivingFile?.delete();
            _resetFileReception();
          } else if (data['type'] == 'command') {
            if (data['command'] == 'send_files') {
              // Server requested files from client
              // You can handle this if needed
            }
          } else {
            setState(() {
              _status = 'Received unknown message type.';
            });
            print(
                'Received unknown message type: ${data['type']}'); // Debugging print
          }
        } else {
          setState(() {
            _status = 'Received unexpected binary data.';
          });
          print('Received unexpected binary data.'); // Debugging print
        }
      } catch (e) {
        setState(() {
          _status = 'Error receiving data: $e';
          _isLoading = false;
          _receiveProgress = 0.0;
        });
        print('Error receiving data: $e'); // Debugging print
        await _fileSink?.close();
        _receivingFile?.delete();
        _resetFileReception();
      }
    }, onDone: () {
      setState(() {
        _status = 'Connection closed.';
        _isLoading = false;
        _receiveProgress = 0.0;
      });
      _resetFileReception();
    }, onError: (error) {
      setState(() {
        _status = 'Error: $error';
        _isLoading = false;
        _receiveProgress = 0.0;
      });
      print('Connection error: $error'); // Debugging print
      _resetFileReception();
    });
  }

  Future<void> _prepareToReceiveFile(Map<String, dynamic> metadata) async {
    _receivingFilename = metadata['filename'];
    _receivingFilesize = metadata['filesize'];

    // Get the default directory
    Directory? directory;

    try {
      if (Platform.isAndroid) {
        // Request storage permissions
        if (!await _requestPermissions()) {
          setState(() {
            _status = 'Storage permission denied.';
          });
          // Send a cancel message to the server
          Map<String, dynamic> cancelMessage = {'type': 'cancel'};
          String cancelJson = jsonEncode(cancelMessage);
          _channel?.sink.add(cancelJson);
          return;
        }

        directory = Directory('/storage/emulated/0/Download/PC Files');
      } else if (Platform.isIOS) {
        directory = await getApplicationDocumentsDirectory();
        directory = Directory(directory.path + '/PC Files');
      } else {
        // For other platforms, use current directory or specify as needed
        directory = await getDownloadsDirectory();
        directory = Directory('${directory!.path}/PC Files');
      }

      // Create the directory if it doesn't exist
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      String filePath = '${directory.path}/$_receivingFilename';
      _receivingFile = File(filePath);

      try {
        _fileSink = _receivingFile!.openWrite();
      } catch (e) {
        setState(() {
          _status = 'Error opening file: $e';
        });
        print('Error opening file: $e'); // Debugging print
        // Send a cancel message to the server
        Map<String, dynamic> cancelMessage = {'type': 'cancel'};
        String cancelJson = jsonEncode(cancelMessage);
        _channel?.sink.add(cancelJson);
        return;
      }
      _bytesReceived = 0;

      // Initialize transfer statistics
      _transferStartTime = DateTime.now();
      _totalBytesToTransfer = _receivingFilesize;
      _bytesTransferred = 0;
      _transferSpeed = 0.0;
      _estimatedTimeRemaining = '';

      // Initialize hash object
      _receivedFileHash = sha256.convert([]);

      setState(() {
        _isLoading = true;
        _status = 'Receiving $_receivingFilename...';
        _receiveProgress = 0.0;
      });
    } catch (e) {
      setState(() {
        _status = 'Error preparing to receive file: $e';
      });
      print('Error preparing to receive file: $e'); // Debugging print
      // Send a cancel message to the server
      Map<String, dynamic> cancelMessage = {'type': 'cancel'};
      String cancelJson = jsonEncode(cancelMessage);
      _channel?.sink.add(cancelJson);
      return;
    }
  }

  Future<bool> _requestPermissions() async {
    var status = await Permission.storage.status;
    if (status.isGranted) {
      return true;
    } else {
      status = await Permission.storage.request();
      return status.isGranted;
    }
  }

  void _updateReceiveProgress() {
    setState(() {
      _receiveProgress = _bytesReceived / _receivingFilesize;

      // Calculate transfer speed and estimated time remaining
      Duration elapsed = DateTime.now().difference(_transferStartTime!);
      if (elapsed.inSeconds > 0) {
        _transferSpeed = _bytesTransferred /
            elapsed.inSeconds.toDouble(); // bytes per second

        int bytesRemaining = _totalBytesToTransfer - _bytesTransferred;
        double timeRemainingSeconds = bytesRemaining / _transferSpeed;
        _estimatedTimeRemaining =
            _formatDuration(Duration(seconds: timeRemainingSeconds.round()));
      } else {
        _transferSpeed = 0.0;
        _estimatedTimeRemaining = 'Calculating...';
      }
    });
  }

  void _resetFileReception() {
    _fileSink = null;
    _receivingFile = null;
    _receivingFilename = null;
    _receivingFilesize = 0;
    _bytesReceived = 0;
    _receivedFileHash = null;
    _receiveProgress = 0.0;
  }

  Future<void> _pickFilesToSend() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.paths.isNotEmpty) {
      setState(() {
        _selectedFiles = result.paths
            .map((path) => FileTransferInfo(file: File(path!)))
            .toList();
        _status = 'Files selected.';
      });
    } else {
      setState(() {
        _status = 'File selection canceled.';
      });
    }
  }

  void _startFileTransfer() async {
    if (_selectedFiles.isEmpty) {
      setState(() {
        _status = 'No files selected to send.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    for (FileTransferInfo fileInfo in _selectedFiles) {
      File file = fileInfo.file;
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
        fileInfo.status = 'Sending';
        fileInfo.progress = 0.0;
      });

      // Initialize hash object
      Digest fileHash = sha256.convert([]);

      // Send file content in chunks
      Stream<List<int>> stream = file.openRead();
      int bytesSent = 0;

      try {
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

          // Update hash
          fileHash = sha256.convert([...fileHash.bytes, ...chunk]);

          // Calculate progress and update UI
          setState(() {
            fileInfo.progress = bytesSent / filesize;
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
      } catch (e) {
        setState(() {
          _status = 'Error sending file $filename: $e';
          fileInfo.status = 'Error';
        });
        continue; // Move to next file
      }

      // Send end message
      Map<String, dynamic> endMessage = {'type': 'end'};
      String endJson = jsonEncode(endMessage);
      _channel?.sink.add(endJson);

      // Send file hash
      Map<String, dynamic> hashMessage = {
        'type': 'hash',
        'hash': fileHash.toString(),
      };
      String hashJson = jsonEncode(hashMessage);
      _channel?.sink.add(hashJson);

      setState(() {
        _status = 'File $filename sent.';
        fileInfo.status = 'Sent';
        fileInfo.progress = 1.0;
        _transferSpeed = 0.0;
        _estimatedTimeRemaining = '';
      });
    }

    setState(() {
      _isLoading = false;
      _status = 'All files sent.';
      // Optionally, clear selected files after sending
      //_selectedFiles.clear();
    });
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
        title: const Text('File Transfer'),
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
                    decoration: const InputDecoration(
                      labelText: 'Server IP Address',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _connect,
                  child: const Text('Connect'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // File Selection and Transfer Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _pickFilesToSend,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Select Files'),
                ),
                ElevatedButton.icon(
                  onPressed:
                      (_channel == null || _selectedFiles.isEmpty || _isLoading)
                          ? null
                          : _startFileTransfer,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Start Transfer'),
                ),
              ],
            ),

            ElevatedButton.icon(
              onPressed: _channel == null ? null : _requestFilesFromServer,
              icon: const Icon(Icons.download),
              label: const Text('Receive Files'),
            ),

            const SizedBox(height: 20),
            // Selected Files List with Progress Indicators
            if (_selectedFiles.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: _selectedFiles.length,
                  itemBuilder: (context, index) {
                    FileTransferInfo fileInfo = _selectedFiles[index];
                    String fileName = fileInfo.file.path.split('/').last;
                    return ListTile(
                      title: Text(fileName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(value: fileInfo.progress),
                          const SizedBox(height: 5),
                          Text(
                              '${(fileInfo.progress * 100).toStringAsFixed(2)}% - ${fileInfo.status}'),
                        ],
                      ),
                    );
                  },
                ),
              ),
            // Receiving File Progress Indicator
            if (_isLoading && _receiveProgress > 0)
              Column(
                children: [
                  LinearProgressIndicator(value: _receiveProgress),
                  const SizedBox(height: 10),
                  Text('${(_receiveProgress * 100).toStringAsFixed(2)}%'),
                  const SizedBox(height: 10),
                  Text('Speed: ${_formatSpeed(_transferSpeed)}'),
                  Text('Time remaining: $_estimatedTimeRemaining'),
                ],
              ),
            const SizedBox(height: 20),
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

class FileTransferInfo {
  File file;
  double progress;
  String status;

  FileTransferInfo({
    required this.file,
    this.progress = 0.0,
    this.status = 'Pending',
  });
}
