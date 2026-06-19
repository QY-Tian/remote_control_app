import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../models/device.dart';

/// 信令服务 - 支持两种模式：
/// 
/// 1. Firebase 模式（跨网络）: 使用 Firebase Realtime DB 作为信令通道
///    - 无需自建服务器
///    - 免费额度：1GB 存储 + 10GB/月流量
///    - 支持全球任意网络环境
/// 
/// 2. 局域网直连模式（同一 WiFi）: 使用 UDP 广播发现设备
///    - 完全离线，无需互联网
///    - 超低延迟
///    - 仅限同一局域网
///
/// Firebase 数据结构：
/// /devices/{deviceId}           -> 设备信息
/// /signals/{targetDeviceId}/    -> 信令消息队列
///   /pair_request/{messageId}   -> 配对请求
///   /pair_response/{messageId}  -> 配对响应
///   /offer/{messageId}          -> WebRTC Offer
///   /answer/{messageId}         -> WebRTC Answer
///   /ice/{messageId}            -> ICE Candidate
///   /disconnect/{messageId}     -> 断开通知

enum SignalingMode {
  firebase,   // 跨网络（需要互联网）
  lan,        // 局域网直连（不需要互联网）
}

class SignalingService extends ChangeNotifier {
  // Firebase
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  
  // 局域网
  static const int _lanDiscoveryPort = 19876;
  RawDatagramSocket? _lanSocket;
  Timer? _lanBroadcastTimer;
  Timer? _lanCleanupTimer;
  
  // 通用状态
  Device? _currentDevice;
  Device? get currentDevice => _currentDevice;
  
  SignalingMode _mode = SignalingMode.firebase;
  SignalingMode get mode => _mode;
  
  final List<Device> _discoveredDevices = [];
  List<Device> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  
  final Map<String, Device> _pairedDevices = {};
  Map<String, Device> get pairedDevices => Map.unmodifiable(_pairedDevices);
  
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  String? _error;
  String? get error => _error;
  
  // Firebase 监听订阅
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _signalsSubscription;
  final Set<String> _processedSignals = {}; // 防止重复处理
  
  // 局域网设备缓存
  final Map<String, DateTime> _lanDevices = {};
  
  // Stream controllers
  final _offerController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOffer => _offerController.stream;
  
  final _answerController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onAnswer => _answerController.stream;
  
  final _iceCandidateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onIceCandidate => _iceCandidateController.stream;
  
  final _pairRequestController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairRequest => _pairRequestController.stream;
  
  final _pairResponseController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairResponse => _pairResponseController.stream;
  
  final _disconnectController = StreamController<String>.broadcast();
  Stream<String> get onDisconnect => _disconnectController.stream;

  static String generatePairingCode() {
    final random = Random();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  /// 连接到信令通道
  Future<void> connect({
    required Device device,
    SignalingMode mode = SignalingMode.firebase,
  }) async {
    _currentDevice = device;
    _mode = mode;
    _error = null;
    
    try {
      switch (mode) {
        case SignalingMode.firebase:
          await _connectFirebase(device);
          break;
        case SignalingMode.lan:
          await _connectLan(device);
          break;
      }
      
      _isConnected = true;
      notifyListeners();
      
    } catch (e) {
      _error = '连接失败: $e';
      notifyListeners();
    }
  }

  // ==================== Firebase 模式 ====================
  
  Future<void> _connectFirebase(Device device) async {
    // 注册设备到 Firebase
    final deviceRef = _dbRef.child('devices').child(device.id);
    await deviceRef.set({
      'id': device.id,
      'name': device.name,
      'role': device.role.name,
      'type': device.type.name,
      'ipAddress': device.ipAddress ?? '',
      'lastSeen': ServerValue.timestamp,
      'status': 'online',
    });
    
    // 设备断开时自动清理
    deviceRef.onDisconnect().remove();
    
    // 定期更新心跳
    Timer.periodic(const Duration(seconds: 20), (_) {
      deviceRef.child('lastSeen').set(ServerValue.timestamp);
    });
    
    // 监听设备列表变化
    _devicesSubscription = _dbRef
        .child('devices')
        .orderByChild('lastSeen')
        .startAt(DateTime.now().subtract(const Duration(minutes: 2)).millisecondsSinceEpoch)
        .onValue
        .listen(_onFirebaseDevicesUpdate);
    
    // 监听发给自己的信令消息
    _signalsSubscription = _dbRef
        .child('signals')
        .child(device.id)
        .onChildAdded
        .listen(_onFirebaseSignal);
  }

  void _onFirebaseDevicesUpdate(DatabaseEvent event) {
    final data = event.snapshot.value;
    if (data == null || data is! Map) return;
    
    _discoveredDevices.clear();
    
    (data as Map<dynamic, dynamic>).forEach((key, value) {
      try {
        final deviceMap = Map<String, dynamic>.from(value as Map);
        final device = Device.fromJson(deviceMap);
        
        // 只添加非当前设备且角色不同的在线设备
        if (device.id != _currentDevice?.id && 
            device.role != _currentDevice?.role &&
            device.status != DeviceStatus.offline) {
          _discoveredDevices.add(device);
        }
      } catch (e) {
        if (kDebugMode) print('设备解析错误: $e');
      }
    });
    
    notifyListeners();
  }

  void _onFirebaseSignal(DatabaseEvent event) {
    final data = event.snapshot.value;
    if (data == null) return;
    
    final signal = Map<String, dynamic>.from(data as Map);
    final messageId = event.snapshot.key ?? '';
    
    // 防止重复处理
    if (_processedSignals.contains(messageId)) return;
    _processedSignals.add(messageId);
    
    // 清理旧的已处理消息
    if (_processedSignals.length > 100) {
      _processedSignals.remove(_processedSignals.first);
    }
    
    // 处理完删除消息
    _dbRef.child('signals').child(_currentDevice?.id ?? '').child(messageId).remove();
    
    final type = signal['type'] as String?;
    switch (type) {
      case 'pair_request':
        _pairRequestController.add(signal);
        break;
      case 'pair_response':
        _handlePairResponse(signal);
        _pairResponseController.add(signal);
        break;
      case 'offer':
        _offerController.add(signal);
        break;
      case 'answer':
        _answerController.add(signal);
        break;
      case 'ice_candidate':
        _iceCandidateController.add(signal);
        break;
      case 'disconnect':
        final fromId = signal['from'] as String?;
        if (fromId != null) {
          _pairedDevices.remove(fromId);
          _disconnectController.add(fromId);
          notifyListeners();
        }
        break;
    }
  }

  /// 发送 Firebase 信令消息
  void _sendFirebaseSignal(String targetDeviceId, Map<String, dynamic> data) {
    final signalRef = _dbRef
        .child('signals')
        .child(targetDeviceId)
        .push();
    
    signalRef.set({
      ...data,
      'from': _currentDevice?.id,
      'timestamp': ServerValue.timestamp,
    });
    
    // 30秒后自动清理
    Future.delayed(const Duration(seconds: 30), () {
      signalRef.remove();
    });
  }

  // ==================== 局域网模式 ====================
  
  Future<void> _connectLan(Device device) async {
    final ip = device.ipAddress;
    if (ip == null || ip.isEmpty) {
      throw Exception('无法获取本机 IP，请确保已连接 WiFi');
    }
    
    // 创建 UDP Socket
    _lanSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _lanDiscoveryPort);
    
    _lanSocket!.broadcastEnabled = true;
    _lanSocket!.multicastLoopback = false;
    
    // 监听来自其他设备的广播
    _lanSocket!.listen(_onLanData);
    
    // 定期广播自己的存在
    _lanBroadcastTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _lanBroadcastPresence(),
    );
    
    // 立即广播一次
    _lanBroadcastPresence();
    
    // 清理超时设备
    _lanCleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _lanCleanupDevices(),
    );
  }

  void _lanBroadcastPresence() {
    if (_lanSocket == null || _currentDevice == null) return;
    
    final message = jsonEncode({
      'type': 'presence',
      'device': _currentDevice!.toJson(),
    });
    
    final data = Uint8List.fromList(message.codeUnits);
    final broadcastAddr = InternetAddress('255.255.255.255');
    
    _lanSocket!.send(data, broadcastAddr, _lanDiscoveryPort);
  }

  void _onLanData(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = _lanSocket?.receive();
      if (datagram == null) return;
      
      try {
        final message = String.fromCharCodes(datagram.data);
        final data = jsonDecode(message);
        final type = data['type'] as String?;
        
        switch (type) {
          case 'presence':
            _handleLanPresence(data['device']);
            break;
          case 'pair_request':
          case 'pair_response':
          case 'offer':
          case 'answer':
          case 'ice_candidate':
          case 'disconnect':
            _handleLanSignal(data);
            break;
        }
      } catch (e) {
        if (kDebugMode) print('局域网消息解析错误: $e');
      }
    }
  }

  void _handleLanPresence(Map<String, dynamic>? deviceData) {
    if (deviceData == null) return;
    
    try {
      final device = Device.fromJson(deviceData);
      
      // 更新设备缓存
      _lanDevices[device.id] = DateTime.now();
      
      // 更新发现列表
      if (device.id != _currentDevice?.id && 
          device.role != _currentDevice?.role) {
        final existingIndex = _discoveredDevices.indexWhere((d) => d.id == device.id);
        if (existingIndex >= 0) {
          _discoveredDevices[existingIndex] = device.copyWith(status: DeviceStatus.online);
        } else {
          _discoveredDevices.add(device.copyWith(status: DeviceStatus.online));
        }
        notifyListeners();
      }
    } catch (e) {
      if (kDebugMode) print('局域网设备解析错误: $e');
    }
  }

  void _handleLanSignal(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    switch (type) {
      case 'pair_request':
        _pairRequestController.add(data);
        break;
      case 'pair_response':
        _handlePairResponse(data);
        _pairResponseController.add(data);
        break;
      case 'offer':
        _offerController.add(data);
        break;
      case 'answer':
        _answerController.add(data);
        break;
      case 'ice_candidate':
        _iceCandidateController.add(data);
        break;
      case 'disconnect':
        final fromId = data['from'] as String?;
        if (fromId != null) {
          _pairedDevices.remove(fromId);
          _disconnectController.add(fromId);
          notifyListeners();
        }
        break;
    }
  }

  void _lanCleanupDevices() {
    final now = DateTime.now();
    final toRemove = <String>[];
    
    _lanDevices.forEach((id, lastSeen) {
      if (now.difference(lastSeen).inSeconds > 10) {
        toRemove.add(id);
      }
    });
    
    toRemove.forEach((id) {
      _lanDevices.remove(id);
      _discoveredDevices.removeWhere((d) => d.id == id);
    });
    
    if (toRemove.isNotEmpty) notifyListeners();
  }

  /// 发送局域网信令消息
  void _sendLanSignal(String targetDeviceId, Map<String, dynamic> data) {
    if (_lanSocket == null) return;
    
    // 通过局域网直发给目标设备
    final targetDevice = _discoveredDevices.firstWhere(
      (d) => d.id == targetDeviceId,
      orElse: () => _pairedDevices[targetDeviceId] ?? 
        Device(id: targetDeviceId, name: '', role: DeviceRole.controlled, type: DeviceType.unknown),
    );
    
    final ip = targetDevice.ipAddress;
    if (ip == null || ip.isEmpty) return;
    
    final message = jsonEncode(data);
    final sendData = Uint8List.fromList(message.codeUnits);
    
    try {
      _lanSocket!.send(sendData, InternetAddress(ip), _lanDiscoveryPort);
    } catch (e) {
      if (kDebugMode) print('局域网发送失败: $e');
    }
  }

  // ==================== 通用接口 ====================

  void sendPairRequest(String targetDeviceId, String pairingCode) {
    final data = {
      'type': 'pair_request',
      'to': targetDeviceId,
      'pairingCode': pairingCode,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void sendPairResponse(String targetDeviceId, bool accepted) {
    final data = {
      'type': 'pair_response',
      'to': targetDeviceId,
      'accepted': accepted,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void sendOffer(String targetDeviceId, String sdp) {
    final data = {
      'type': 'offer',
      'to': targetDeviceId,
      'sdp': sdp,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void sendAnswer(String targetDeviceId, String sdp) {
    final data = {
      'type': 'answer',
      'to': targetDeviceId,
      'sdp': sdp,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void sendIceCandidate(String targetDeviceId, Map<String, dynamic> candidate) {
    final data = {
      'type': 'ice_candidate',
      'to': targetDeviceId,
      'candidate': candidate,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void sendDisconnect(String targetDeviceId) {
    final data = {
      'type': 'disconnect',
      'to': targetDeviceId,
    };
    
    if (_mode == SignalingMode.firebase) {
      _sendFirebaseSignal(targetDeviceId, data);
    } else {
      _sendLanSignal(targetDeviceId, data);
    }
  }

  void _handlePairResponse(Map<String, dynamic> data) {
    final accepted = data['accepted'] as bool? ?? false;
    final fromId = data['from'] as String?;
    
    if (accepted && fromId != null) {
      final device = _discoveredDevices.firstWhere(
        (d) => d.id == fromId,
        orElse: () => Device(
          id: fromId,
          name: '未知设备',
          role: _currentDevice?.role == DeviceRole.controller 
            ? DeviceRole.controlled 
            : DeviceRole.controller,
          type: DeviceType.unknown,
        ),
      );
      
      _pairedDevices[fromId] = device.copyWith(status: DeviceStatus.connected);
      notifyListeners();
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _devicesSubscription?.cancel();
    _signalsSubscription?.cancel();
    _lanBroadcastTimer?.cancel();
    _lanCleanupTimer?.cancel();
    _lanSocket?.close();
    
    // 从 Firebase 移除设备
    if (_mode == SignalingMode.firebase && _currentDevice != null) {
      await _dbRef.child('devices').child(_currentDevice!.id).remove();
    }
    
    _isConnected = false;
    _discoveredDevices.clear();
    _processedSignals.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _offerController.close();
    _answerController.close();
    _iceCandidateController.close();
    _pairRequestController.close();
    _pairResponseController.close();
    _disconnectController.close();
    super.dispose();
  }
}
