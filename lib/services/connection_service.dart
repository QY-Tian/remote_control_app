import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import '../models/device.dart';
import 'signaling_service.dart';
import 'webrtc_service.dart';

/// 连接管理服务 - 协调信令服务和 WebRTC 服务
class ConnectionService extends ChangeNotifier {
  final SignalingService _signaling = SignalingService();
  final WebRTCService _webrtc = WebRTCService();
  
  SignalingService get signaling => _signaling;
  WebRTCService get webrtc => _webrtc;
  
  Device? _currentDevice;
  Device? get currentDevice => _currentDevice;
  
  Device? _connectedDevice;
  Device? get connectedDevice => _connectedDevice;
  
  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;
  
  String? _connectionError;
  String? get connectionError => _connectionError;
  
  String? _currentPairingCode;
  String? get currentPairingCode => _currentPairingCode;
  
  SignalingMode _currentMode = SignalingMode.firebase;
  SignalingMode get currentMode => _currentMode;
  
  StreamSubscription? _offerSubscription;
  StreamSubscription? _answerSubscription;
  StreamSubscription? _iceCandidateSubscription;
  StreamSubscription? _pairRequestSubscription;
  StreamSubscription? _pairResponseSubscription;
  StreamSubscription? _disconnectSubscription;

  Future<void> initializeDevice(DeviceRole role) async {
    final prefs = await SharedPreferences.getInstance();
    
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString('device_id', deviceId);
    }
    
    String deviceName = prefs.getString('device_name') ?? '';
    if (deviceName.isEmpty) {
      deviceName = await _getDeviceName();
      await prefs.setString('device_name', deviceName);
    }
    
    final deviceType = Platform.isIOS 
      ? DeviceType.ios 
      : Platform.isAndroid 
        ? DeviceType.android 
        : DeviceType.unknown;
    
    String? ipAddress;
    try {
      final networkInfo = NetworkInfo();
      ipAddress = await networkInfo.getWifiIP();
    } catch (e) {
      if (kDebugMode) print('获取 IP 地址失败: $e');
    }
    
    _currentDevice = Device(
      id: deviceId,
      name: deviceName,
      role: role,
      type: deviceType,
      ipAddress: ipAddress,
      lastSeen: DateTime.now(),
    );
    
    notifyListeners();
  }

  Future<void> updateDeviceName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
    
    if (_currentDevice != null) {
      _currentDevice = _currentDevice!.copyWith(name: name);
      notifyListeners();
    }
  }

  /// 连接到信令通道（支持两种模式）
  Future<void> connectToSignaling({SignalingMode mode = SignalingMode.firebase}) async {
    if (_currentDevice == null) {
      _connectionError = '设备未初始化';
      notifyListeners();
      return;
    }
    
    _currentMode = mode;
    _connectionError = null;
    notifyListeners();
    
    await _signaling.connect(
      device: _currentDevice!,
      mode: mode,
    );
    
    _setupSignalingListeners();
  }

  Future<void> disconnectAll() async {
    await _webrtc.closeConnection();
    await _signaling.disconnect();
    
    _connectedDevice = null;
    _currentPairingCode = null;
    _isConnecting = false;
    
    _cancelSubscriptions();
    notifyListeners();
  }

  Future<void> startPairing(String targetDeviceId) async {
    if (!_signaling.isConnected) {
      _connectionError = '未连接到信令通道';
      notifyListeners();
      return;
    }
    
    _isConnecting = true;
    _currentPairingCode = SignalingService.generatePairingCode();
    _connectionError = null;
    notifyListeners();
    
    _signaling.sendPairRequest(targetDeviceId, _currentPairingCode!);
  }

  void respondToPairRequest(String fromDeviceId, bool accepted) {
    _signaling.sendPairResponse(fromDeviceId, accepted);
    
    if (accepted) {
      _isConnecting = true;
      notifyListeners();
    }
  }

  Future<void> establishWebRTCConnection(String targetDeviceId) async {
    if (_currentDevice == null) return;
    
    try {
      if (_currentDevice!.role == DeviceRole.controlled) {
        await _webrtc.createConnectionAsControlled(_signaling);
      } else {
        await _webrtc.createConnectionAsController(_signaling, targetDeviceId);
      }
      
      _connectedDevice = _signaling.discoveredDevices.firstWhere(
        (d) => d.id == targetDeviceId,
        orElse: () => Device(
          id: targetDeviceId,
          name: '已连接设备',
          role: _currentDevice!.role == DeviceRole.controller 
            ? DeviceRole.controlled 
            : DeviceRole.controller,
          type: DeviceType.unknown,
        ),
      );
      
      notifyListeners();
      
    } catch (e) {
      _connectionError = '建立连接失败: $e';
      _isConnecting = false;
      notifyListeners();
    }
  }

  void _setupSignalingListeners() {
    _cancelSubscriptions();
    
    _offerSubscription = _signaling.onOffer.listen((data) async {
      final fromId = data['from'] as String?;
      final sdp = data['sdp'] as String?;
      if (fromId != null && sdp != null) {
        await _webrtc.handleOffer(_signaling, fromId, sdp);
      }
    });
    
    _answerSubscription = _signaling.onAnswer.listen((data) async {
      final sdp = data['sdp'] as String?;
      if (sdp != null) {
        await _webrtc.handleAnswer(sdp);
      }
    });
    
    _iceCandidateSubscription = _signaling.onIceCandidate.listen((data) async {
      final candidate = data['candidate'] as Map<String, dynamic>?;
      if (candidate != null) {
        await _webrtc.handleIceCandidate(candidate);
      }
    });
    
    _pairRequestSubscription = _signaling.onPairRequest.listen((data) {
      final fromId = data['from'] as String?;
      final pairingCode = data['pairingCode'] as String?;
      if (fromId != null && pairingCode != null) {
        respondToPairRequest(fromId, true);
      }
    });
    
    _pairResponseSubscription = _signaling.onPairResponse.listen((data) async {
      final accepted = data['accepted'] as bool? ?? false;
      final fromId = data['from'] as String?;
      
      if (accepted && fromId != null) {
        await establishWebRTCConnection(fromId);
      } else {
        _isConnecting = false;
        _connectionError = '配对被拒绝';
        notifyListeners();
      }
    });
    
    _disconnectSubscription = _signaling.onDisconnect.listen((deviceId) {
      if (_connectedDevice?.id == deviceId) {
        _connectedDevice = null;
        _isConnecting = false;
        _webrtc.closeConnection();
        notifyListeners();
      }
    });
  }

  void _cancelSubscriptions() {
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceCandidateSubscription?.cancel();
    _pairRequestSubscription?.cancel();
    _pairResponseSubscription?.cancel();
    _disconnectSubscription?.cancel();
  }

  Future<String> _getDeviceName() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.name ?? 'iOS Device';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.model ?? 'Android Device';
      }
    } catch (e) {
      if (kDebugMode) print('获取设备信息失败: $e');
    }
    return 'Unknown Device';
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    _webrtc.dispose();
    _signaling.dispose();
    super.dispose();
  }
}
