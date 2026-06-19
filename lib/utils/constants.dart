/// 应用常量
class AppConstants {
  // 服务器配置
  static const String defaultSignalingServer = 'wss://your-signaling-server.com/ws';
  static const String defaultStunServer = 'stun:stun.l.google.com:19302';
  
  // 连接配置
  static const int heartbeatIntervalSeconds = 30;
  static const int reconnectDelaySeconds = 5;
  static const int connectionTimeoutSeconds = 30;
  
  // 视频配置
  static const int videoWidth = 1280;
  static const int videoHeight = 720;
  static const int videoFrameRate = 15;
  static const int videoBitrate = 2000000; // 2 Mbps
  
  // 控制配置
  static const int touchEventThrottleMs = 16; // ~60fps
  static const int keyEventDelayMs = 50;
  
  // 配对码
  static const int pairingCodeLength = 6;
  
  // 存储键
  static const String prefDeviceId = 'device_id';
  static const String prefDeviceName = 'device_name';
  static const String prefServerUrl = 'server_url';
  static const String prefPairedDevices = 'paired_devices';
}
