import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

const FileShareService = "_fileshare._tcp";
const FileShareServiceName = "本地文件传输";

void main() {
  runApp(MyApp());
}

class HostInfo {
  static const platform = MethodChannel('com.example.hostinfo');

  // 获取主机名
  static Future<String?> getHostName() async {
    if (kIsWeb) {
      return "Not supported on web";
    } else if (Platform.isAndroid || Platform.isIOS) {
      try {
        final String? hostName = await platform.invokeMethod('getHostName');
        return hostName;
      } on PlatformException catch (e) {
        print("Failed to get host name: '${e.message}'.");
        return null;
      }
    } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      try {
        // 使用dart:io的功能在桌面系统上获取主机名
        return Platform.localHostname;
      } catch (e) {
        print("Failed to get host name: $e");
        return null;
      }
    } else {
      return "Unsupported platform";
    }
  }
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MDnsPage(),
    );
  }
}

class MDnsPage extends StatefulWidget {
  @override
  _MDnsPageState createState() => _MDnsPageState();
}

class _MDnsPageState extends State<MDnsPage> {
  bool isRegistered = false;
  bool isRegistering = false;
  List<BonsoirService> services = [];
  bool isDiscovering = false;
  BonsoirBroadcast? broadcast;

  // 文件传输的Server
  ServerSocket? serverSocket;
  // 本地文件存储路径
  String? savePath;
  // 服务发现超时时间
  int discoveryTimeout = 10; // seconds
  File? selectedFile;
  String? hostname;
  String? ipAddress;
  String? selectedFileName;
  double progress = 0.0;

  @override
  void initState() {
    super.initState();
    _getSavePath();
    _getHostName();
    _getIpAddress();
  }


  @override
  void dispose() {
    broadcast?.stop();
    serverSocket?.close();
    super.dispose();
  }

  Future<void> _getSavePath() async {
    final directory = await getApplicationDocumentsDirectory();
    setState(() {
      savePath = directory.path;
    });
  }

  Future<void> _getHostName() async {
    final host = await HostInfo.getHostName();
    setState(() {
      hostname = host;
    });
  }

  Future<void> _getIpAddress() async {
    try {
      // 获取所有的网络接口
      for (var interface in await NetworkInterface.list()) {
        // 遍历每个接口的地址
        for (var address in interface.addresses) {
          // 检查是否是IPv4地址
          if (address.type == InternetAddressType.IPv4) {
            setState(() {
              // 设置为第一个ipv4地址
              ipAddress = address.address;
            });
            return;
          }
        }
      }
    } catch (e) {
      print('Failed to get IP address: $e');
    }
  }

  Future<void> _registerService() async {
    // 服务注册需要启动并注册到mDNS中
    if (isRegistering) return;

    setState(() {
      isRegistering = true;
    });

    // 1. 启动服务, 设置为随机端口
    final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    // todo 未来可能需要, 存储复杂的每个连接节点的状态
    // final fileServer = FileServer();

    // 2. 注册并说明服务的端口
    final BonsoirService service = BonsoirService(
      name: FileShareServiceName,
      type: FileShareService,
      port: serverSocket.port,
      attributes: {'ip': ipAddress!,
        'host': hostname!},
    );

    // 3. 服务开始启动并设置监听回调
    serverSocket.listen((Socket client) {
      final clientId = client.remoteAddress.address;
      print('Client connected: $clientId');

      final buffer = BytesBuilder();
      int? fileNameLength;
      int? fileSize;
      String? fileName;
      IOSink? fileSink;

      client.listen(
            (Uint8List data) async {
          buffer.add(data);

          try {
            final bytes = buffer.toBytes(); // 获取当前缓冲区内容，但不清空
            int offset = 0;

            // 读取文件名长度（int32）
            if (fileNameLength == null && bytes.length >= offset + 4) {
              fileNameLength = _bytesToInt32(bytes.sublist(offset, offset + 4));
              offset += 4;
              print('File name length: $fileNameLength');
            }

            // 读取文件大小（int32）
            if (fileNameLength != null && fileSize == null && bytes.length >= offset + 4) {
              fileSize = _bytesToInt32(bytes.sublist(offset, offset + 4));
              offset += 4;
              print('File size: $fileSize');
            }

            // 读取文件名称
            if (fileNameLength != null &&
                fileSize != null &&
                fileName == null &&
                bytes.length >= offset + fileNameLength!) {
              final nameBytes = bytes.sublist(offset, offset + fileNameLength!);
              fileName = utf8.decode(nameBytes);
              offset += fileNameLength!;
              print('File name: $fileName');

              // 创建文件路径并确保文件内容被清空
              final fullPath = path.join(savePath!, fileName);
              File file = File(fullPath);
              print("Full Path: $fullPath");
              file.writeAsBytesSync([]); // 清空文件内容, 也会关闭文件

              fileSink = File(fullPath).openWrite(mode: FileMode.append); // 以追加模式写入
            }

            // 读取文件内容并追加写入文件
            if (fileSink != null && bytes.length > offset) {
              final content = bytes.sublist(offset);
              fileSink?.add(content);

              // 更新接收到的文件内容大小
              if (fileSize != null && content.isNotEmpty) {
                int receivedSize = content.length;
                // await fileSink?.flush();
                print('Received ${receivedSize} bytes of $fileSize bytes.');
              }
            }

            // 移除已经处理过的字节
            buffer.clear();
            buffer.add(bytes.sublist(offset)); // 只保留未处理的部分
          } catch (e) {
            print('Error processing data from client $clientId: $e');
            client.destroy();
          }
        },
        onDone: () async {
          print('Client $clientId disconnected.');
          await fileSink?.flush();
          fileSink?.close();
          client.close();
        },
        onError: (error) {
          print('Error with client $clientId: $error');
          fileSink?.close();
          client.close();
        },
      );
    });

    broadcast = BonsoirBroadcast(service: service);
    await broadcast!.ready;
    await broadcast!.start();

    setState(() {
      isRegistered = true;
      isRegistering = false;
    });

    print('Service registered: ${service.name}');
  }


  Future<void> _unregisterService() async {
    if (!isRegistered) return;

    try {
      await broadcast?.stop();
      serverSocket?.close();
      setState(() {
        isRegistered = false;
      });
      print('Service unregistered');
    } catch (e) {
      print('Failed to unregister service: $e');
    }
  }

  Future<void> _discoverServices() async {
    setState(() {
      isDiscovering = true;
      services.clear();
    });
    print('start_discovery');

    BonsoirDiscovery discovery = BonsoirDiscovery(type: FileShareService);
    await discovery.ready;

// If you want to listen to the discovery :
    discovery.eventStream!.listen((event) { // `eventStream` is not null as the discovery instance is "ready" !
      if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
        event.service!.resolve(discovery.serviceResolver); // Should be called when the user wants to connect to this service.
      } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
        setState(() {
          services.removeWhere((s) => s.name == event.service!.name);
          services.add(event.service!);
        });
        print('Service resolved : ${event.service?.toJson()}');
      } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
        setState(() {
          services.removeWhere((s) => s.name == event.service!.name);
        });
        print('Service lost : ${event.service?.toJson()}');
      }
    });
    await discovery.start();

    // 服务发现超时时间
    Future.delayed(Duration(seconds: discoveryTimeout), () {
      discovery.stop();
      setState(() {
        isDiscovering = false;
      });
    });
  }

  Future<void> _sendFile(BonsoirService service) async {
    if (selectedFile == null) return;

    // 这里的host需要重新配置
    Socket socket = await Socket.connect(service.attributes["ip"], service.port);
    final fileNameBytes = utf8.encode(selectedFileName!);
    final fileNameLength = fileNameBytes.length;
    final fileLength = await selectedFile!.length();

    int sendBytes = 0;
    int totalBytes = 4 + fileNameLength + 4 + fileLength;

    // 1. 发送文件名称长度（int32）
    socket.add(_int32ToBytes(fileNameLength));
    await socket.flush();
    sendBytes += 4;

    // 2. 发送文件长度（int32）
    socket.add(_int32ToBytes(fileLength));
    await socket.flush();
    sendBytes += 4;

    // 3. 发送文件名称（UTF-8 编码）
    socket.add(fileNameBytes);
    await socket.flush();
    sendBytes += fileNameLength;

    // 4. 发送文件内容
    await for (final data in selectedFile!.openRead()) {
      socket.add(data);
      await socket.flush();
      sendBytes += data.length;
      setState(() {
        progress = sendBytes / totalBytes;
      });
    }

    // 关闭连接
    await socket.flush();
    socket.destroy();
  }

  Future<void> _selectFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final fileName = path.basename(file.path!); // Extract the file name without directory information

    setState(() {
      selectedFile = File(file.path!);
      selectedFileName = fileName;
      progress = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('File Transfer with mDNS'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: isRegistered ? _unregisterService : (isRegistering ? null : _registerService),
              child: Text(isRegistered ? 'Stop Service' : (isRegistering ? 'Registering...' : 'Register Service')),
            ),
            const SizedBox(height: 16.0),
            ElevatedButton(
              onPressed: isDiscovering ? null : _discoverServices,
              child: Text(isDiscovering ? 'Discovering...' : 'Discover Services'),
            ),
            const SizedBox(height: 16.0),
            ElevatedButton(
              onPressed: _selectFile,
              child: Text(selectedFile != null ? 'File Selected: ${selectedFile!.path}' : 'Select File'),
            ),
            if (selectedFile != null) ...[
              const Divider(), // 添加分割线
              const SizedBox(height: 16.0),
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.grey[300],
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
            ],
            const SizedBox(height: 16.0),
            Divider(),
            Text(savePath != null ? 'Base Directory: $savePath' : 'Loading...'),
            Text(hostname != null && ipAddress != null ? 'Hostname: $hostname, IP Address: $ipAddress' : 'Loading...'),
            const SizedBox(height: 16.0),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: services.length,
                itemBuilder: (context, index) {
                  final service = services[index];
                  return ListTile(
                    title: Text('${service.attributes["host"]},${service.attributes["ip"]}:${service.port}'),
                    subtitle: Text(service.name),
                    trailing: const Icon(Icons.send),
                    onTap: () => _sendFile(service),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ClientFileInfo {
  final String filePath; // 文件路径
  final int expectedSize; // 文件的预期大小
  int receivedSize; // 已经接收到的数据大小

  ClientFileInfo({
    required this.filePath,
    required this.expectedSize,
    this.receivedSize = 0,
  });

  // 更新接收的大小
  void updateReceivedSize(int size) {
    receivedSize += size;
  }

  // 计算接收进度
  double get progress => receivedSize / expectedSize;
}

class FileServer {
  // 存储客户端信息的 Map，键可以是客户端的 IP 地址或自定义的 ID
  final Map<String, ClientFileInfo> clientInfoMap = {};

  // 添加客户端信息
  void addClient(String clientId, String filePath, int expectedSize) {
    clientInfoMap[clientId] = ClientFileInfo(
      filePath: filePath,
      expectedSize: expectedSize,
    );
  }

  // 更新客户端接收的数据大小
  void updateClientReceivedSize(String clientId, int size) {
    if (clientInfoMap.containsKey(clientId)) {
      clientInfoMap[clientId]?.updateReceivedSize(size);
    }
  }

  // 获取客户端的接收进度
  double getClientProgress(String clientId) {
    return clientInfoMap[clientId]?.progress ?? 0.0;
  }

  // 移除客户端信息
  void removeClient(String clientId) {
    clientInfoMap.remove(clientId);
  }
}

// 将 int32 字节数组转换为整数
int _bytesToInt32(List<int> bytes) {
  return ByteData.sublistView(Uint8List.fromList(bytes)).getInt32(0, Endian.big);
}
// 将 int32 转换为字节数组
List<int> _int32ToBytes(int value) {
  var bytes = ByteData(4);
  bytes.setInt32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}