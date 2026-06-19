import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'signaling_service.dart';

/// WebRTC 服务 - 管理 P2P 连接、屏幕画面传输和控制指令
///
/// 架构说明：
/// - Android 被控端: 创建 VideoTrack (屏幕录制) + DataChannel (接收控制指令)
/// - iOS 控制端: 接收 VideoTrack (显示远程屏幕) + DataChannel (发送控制指令)

class WebRTCService extends ChangeNotifier {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  
  // 视频渲染器
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;
  
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  String? _error;
  String? get error => _error;
  
  // 连接状态
  RTCPeerConnectionState? _connectionState;
  RTCPeerConnectionState? get connectionState => _connectionState;
  
  // 控制指令流 (iOS 发送, Android 接收)
  final _controlCommandController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onControlCommand => _controlCommandController.stream;
  
  // 连接状态流
  final _connectionStateController = StreamController<RTCPeerConnectionState>.broadcast();
  Stream<RTCPeerConnectionState> get onConnectionStateChange => _connectionStateController.stream;

  // STUN/TURN 服务器配置
  static const Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      // 生产环境需要配置 TURN 服务器
      // {
      //   'urls': 'turn:your-turn-server.com:3478',
      //   'username': 'user',
      //   'credential': 'pass',
      // },
    ],
  };

  static const Map<String, dynamic> _constraints = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
  };

  /// 初始化渲染器
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      _error = '初始化失败: $e';
      notifyListeners();
    }
  }

  /// 作为被控端 (Android) - 创建 Offer
  Future<void> createConnectionAsControlled(SignalingService signaling) async {
    await initialize();
    
    try {
      // 创建 PeerConnection
      _peerConnection = await createPeerConnection(_iceServers, _constraints);
      
      // 设置连接状态监听
      _peerConnection!.onConnectionState = (state) {
        _connectionState = state;
        _connectionStateController.add(state);
        
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                   state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _isConnected = false;
        }
        notifyListeners();
      };
      
      // 获取屏幕录制流 (Android)
      _localStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 15},
        },
        'audio': false,
      });
      
      // 添加视频轨道到 PeerConnection
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      
      // 设置本地视频预览
      localRenderer.srcObject = _localStream;
      
      // 创建 DataChannel (用于接收控制指令)
      final dataChannelInit = RTCDataChannelInit()
        ..id = 1
        ..ordered = true
        ..maxRetransmits = 30;
      
      _dataChannel = await _peerConnection!.createDataChannel(
        'control',
        dataChannelInit,
      );
      
      _setupDataChannel();
      
      // 监听 ICE Candidate 并发送
      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate != null) {
          signaling.sendIceCandidate(
            signaling.currentDevice?.id ?? '',
            {
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
              'candidate': candidate.candidate,
            },
          );
        }
      };
      
      // 创建 Offer
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      
      // 发送 Offer
      signaling.sendOffer(
        signaling.currentDevice?.id ?? '',
        offer.sdp!,
      );
      
      notifyListeners();
      
    } catch (e) {
      _error = '创建连接失败: $e';
      notifyListeners();
    }
  }

  /// 作为控制端 (iOS) - 接收 Offer 并创建 Answer
  Future<void> createConnectionAsController(
    SignalingService signaling,
    String targetDeviceId,
  ) async {
    await initialize();
    
    try {
      // 创建 PeerConnection
      _peerConnection = await createPeerConnection(_iceServers, _constraints);
      
      // 设置连接状态监听
      _peerConnection!.onConnectionState = (state) {
        _connectionState = state;
        _connectionStateController.add(state);
        
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                   state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _isConnected = false;
        }
        notifyListeners();
      };
      
      // 监听远程视频流
      _peerConnection!.onTrack = (event) {
        if (event.track.kind == 'video') {
          _remoteStream = event.streams[0];
          remoteRenderer.srcObject = _remoteStream;
          notifyListeners();
        }
      };
      
      // 监听 DataChannel (用于发送控制指令)
      _peerConnection!.onDataChannel = (channel) {
        _dataChannel = channel;
        _setupDataChannel();
      };
      
      // 监听 ICE Candidate
      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate != null) {
          signaling.sendIceCandidate(
            targetDeviceId,
            {
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
              'candidate': candidate.candidate,
            },
          );
        }
      };
      
      notifyListeners();
      
    } catch (e) {
      _error = '创建连接失败: $e';
      notifyListeners();
    }
  }

  /// 处理收到的 Offer (被控端收到控制端的 Offer)
  Future<void> handleOffer(
    SignalingService signaling,
    String targetDeviceId,
    String sdp,
  ) async {
    try {
      final offer = RTCSessionDescription(sdp, 'offer');
      await _peerConnection!.setRemoteDescription(offer);
      
      // 创建 Answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      
      // 发送 Answer
      signaling.sendAnswer(targetDeviceId, answer.sdp!);
      
    } catch (e) {
      _error = '处理 Offer 失败: $e';
      notifyListeners();
    }
  }

  /// 处理收到的 Answer (控制端收到被控端的 Answer)
  Future<void> handleAnswer(String sdp) async {
    try {
      final answer = RTCSessionDescription(sdp, 'answer');
      await _peerConnection!.setRemoteDescription(answer);
    } catch (e) {
      _error = '处理 Answer 失败: $e';
      notifyListeners();
    }
  }

  /// 处理 ICE Candidate
  Future<void> handleIceCandidate(Map<String, dynamic> candidateData) async {
    try {
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      if (kDebugMode) {
        print('添加 ICE Candidate 失败: $e');
      }
    }
  }

  /// 发送控制指令 (iOS 调用)
  Future<void> sendControlCommand(Map<String, dynamic> command) async {
    if (_dataChannel != null && 
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      final message = RTCDataChannelMessage(jsonEncode(command));
      await _dataChannel!.send(message);
    }
  }

  /// 发送触摸事件
  Future<void> sendTouchEvent({
    required String action, // 'down', 'move', 'up'
    required double x,
    required double y,
    double? pressure,
  }) async {
    await sendControlCommand({
      'type': 'touch',
      'action': action,
      'x': x,
      'y': y,
      'pressure': pressure ?? 1.0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 发送按键事件
  Future<void> sendKeyEvent({
    required int keyCode,
    required String action, // 'down', 'up'
  }) async {
    await sendControlCommand({
      'type': 'key',
      'keyCode': keyCode,
      'action': action,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 发送滑动事件
  Future<void> sendSwipeEvent({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int durationMs,
  }) async {
    await sendControlCommand({
      'type': 'swipe',
      'startX': startX,
      'startY': startY,
      'endX': endX,
      'endY': endY,
      'duration': durationMs,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 配置 DataChannel
  void _setupDataChannel() {
    _dataChannel?.onMessage = (message) {
      if (message.type == MessageType.text) {
        try {
          final data = jsonDecode(message.text);
          _controlCommandController.add(data);
        } catch (e) {
          if (kDebugMode) {
            print('控制指令解析错误: $e');
          }
        }
      }
    };
    
    _dataChannel?.onDataChannelState = (state) {
      if (kDebugMode) {
        print('DataChannel 状态: $state');
      }
    };
  }

  /// 关闭连接
  Future<void> closeConnection() async {
    _dataChannel?.close();
    _dataChannel = null;
    
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    
    _remoteStream?.dispose();
    _remoteStream = null;
    
    await _peerConnection?.close();
    _peerConnection = null;
    
    _isConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    closeConnection();
    localRenderer.dispose();
    remoteRenderer.dispose();
    _controlCommandController.close();
    _connectionStateController.close();
    super.dispose();
  }
}
