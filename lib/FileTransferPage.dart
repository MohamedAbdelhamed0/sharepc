import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';

class FileTransferApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Transfer App',
      home: FileTransferScreen(),
    );
  }
}

class FileTransferScreen extends StatefulWidget {
  @override
  _FileTransferScreenState createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  final TextEditingController _ipController = TextEditingController();
  String _status = 'Disconnected';

  @override
  void initState() {
    super.initState();
    requestStoragePermission();
  }

  Future<void> requestStoragePermission() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
    }
  }

  void connectToServer() {
    final serverIp = _ipController.text.trim();
    if (serverIp.isEmpty) return;

    setState(() {
      _status = 'Connecting to $serverIp...';
    });

    final channel = IOWebSocketChannel.connect('ws://$serverIp:8765');

    Map<String, dynamic> receiveCommand = {
      'type': 'command',
      'command': 'send_files',
    };
    channel.sink.add(jsonEncode(receiveCommand));

    String? currentFilename;
    int expectedFilesize = 0;
    List<int> fileBytes = [];

    channel.stream.listen((message) async {
      Map<String, dynamic> data = jsonDecode(message);

      if (data['type'] == 'metadata') {
        currentFilename = data['filename'];
        expectedFilesize = data['filesize'];
        fileBytes = [];
        setState(() {
          _status = 'Receiving $currentFilename...';
        });
      } else if (data['type'] == 'data') {
        String content = data['content'];
        List<int> chunk = base64Decode(content);
        fileBytes.addAll(chunk);
      } else if (data['type'] == 'end') {
        // Save the file
        if (currentFilename != null) {
          await saveFile(currentFilename!, fileBytes);
          setState(() {
            _status = 'File $currentFilename received and saved.';
          });
        }
        currentFilename = null;
        fileBytes = [];
      }
    }, onDone: () {
      setState(() {
        _status = 'Disconnected';
      });
    });
  }

  Future<void> saveFile(String filename, List<int> bytes) async {
    await requestStoragePermission();

    Directory? directory;
    if (Platform.isAndroid) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationDocumentsDirectory();
    }

    String newPath = '';
    List<String> paths = directory!.path.split('/');
    for (int x = 1; x < paths.length; x++) {
      String folder = paths[x];
      if (folder != 'Android') {
        newPath += '/$folder';
      } else {
        break;
      }
    }
    newPath = '$newPath/Download/Shared PC';
    directory = Directory(newPath);

    if (!(await directory.exists())) {
      await directory.create(recursive: true);
    }

    File file = File('${directory.path}/$filename');
    await file.writeAsBytes(bytes);
  }

  Future<void> pickAndSendFiles() async {
    await requestStoragePermission();

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );

    if (result != null) {
      for (var file in result.files) {
        await sendFile(File(file.path!), _ipController.text.trim());
      }
    }
  }

  Future<void> sendFile(File file, String serverIp) async {
    final channel = IOWebSocketChannel.connect('ws://$serverIp:8765');

    // Read file contents
    List<int> fileBytes = await file.readAsBytes();
    String filename = file.uri.pathSegments.last;
    int filesize = fileBytes.length;

    // Send metadata
    Map<String, dynamic> metadata = {
      'type': 'metadata',
      'filename': filename,
      'filesize': filesize,
    };
    channel.sink.add(jsonEncode(metadata));

    // Send file data in chunks
    int chunkSize = 4096;
    for (int i = 0; i < fileBytes.length; i += chunkSize) {
      int end =
          (i + chunkSize < fileBytes.length) ? i + chunkSize : fileBytes.length;
      List<int> chunk = fileBytes.sublist(i, end);

      String chunkBase64 = base64Encode(chunk);
      Map<String, dynamic> data = {
        'type': 'data',
        'content': chunkBase64,
      };
      channel.sink.add(jsonEncode(data));
      await Future.delayed(const Duration(milliseconds: 10)); // Yield control
    }

    // Send end message
    Map<String, dynamic> endMessage = {
      'type': 'end',
    };
    channel.sink.add(jsonEncode(endMessage));

    // Close the channel
    await channel.sink.close();

    setState(() {
      _status = 'File $filename sent successfully.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('File Transfer App'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                controller: _ipController,
                decoration: const InputDecoration(
                  labelText: 'Server IP',
                  hintText: 'Enter the server IP address',
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: connectToServer,
                child: const Text('Connect and Receive Files'),
              ),
              ElevatedButton(
                onPressed: pickAndSendFiles,
                child: const Text('Pick and Send Files'),
              ),
              const SizedBox(height: 20),
              Text('Status: $_status'),
            ],
          ),
        ));
  }
}
