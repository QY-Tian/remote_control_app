import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/connection_service.dart';
import '../services/webrtc_service.dart';

/// 被控端界面 (Android) - 显示配对码并等待连接
class ControlledScreen extends StatefulWidget {
  const ControlledScreen({super.key});

  @override
  State<ControlledScreen> createState() => _ControlledScreenState();
}

class _ControlledScreenState extends State<ControlledScreen> {
  String? _pairingCode;
  bool _isWaiting = false;
  StreamSubscription? _commandSubscription;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _startListening();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _commandSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startListening() async {
    final connectionService = context.read<ConnectionService>();
    
    // 连接到信令服务器
    await connectionService.connectToSignaling();
    
    // 监听控制指令
    _commandSubscription = connectionService.webrtc.onControlCommand.listen(
      _handleControlCommand,
    );
  }

  void _handleControlCommand(Map<String, dynamic> command) {
    final type = command['type'] as String?;
    
    switch (type) {
      case 'touch':
        _handleTouchCommand(command);
        break;
      case 'key':
        _handleKeyCommand(command);
        break;
      case 'swipe':
        _handleSwipeCommand(command);
        break;
    }
  }

  void _handleTouchCommand(Map<String, dynamic> command) {
    // 注意：这里需要通过 Android 原生代码注入触摸事件
    // Flutter 层只能接收指令，实际注入需要 MethodChannel 调用原生代码
    final action = command['action'] as String?;
    final x = (command['x'] as num?)?.toDouble() ?? 0;
    final y = (command['y'] as num?)?.toDouble() ?? 0;
    
    // 通过 MethodChannel 发送给 Android 原生层
    // MethodChannel('com.example.remote_control/touch').invokeMethod('injectTouch', {
    //   'action': action,
    //   'x': x,
    //   'y': y,
    // });
    
    debugPrint('Touch: $action at ($x, $y)');
  }

  void _handleKeyCommand(Map<String, dynamic> command) {
    final keyCode = command['keyCode'] as int?;
    final action = command['action'] as String?;
    
    // 通过 MethodChannel 发送给 Android 原生层
    // MethodChannel('com.example.remote_control/key').invokeMethod('injectKey', {
    //   'keyCode': keyCode,
    //   'action': action,
    // });
    
    debugPrint('Key: $keyCode $action');
  }

  void _handleSwipeCommand(Map<String, dynamic> command) {
    final startX = (command['startX'] as num?)?.toDouble() ?? 0;
    final startY = (command['startY'] as num?)?.toDouble() ?? 0;
    final endX = (command['endX'] as num?)?.toDouble() ?? 0;
    final endY = (command['endY'] as num?)?.toDouble() ?? 0;
    final duration = command['duration'] as int? ?? 300;
    
    // 通过 MethodChannel 发送给 Android 原生层
    // MethodChannel('com.example.remote_control/swipe').invokeMethod('injectSwipe', {
    //   'startX': startX,
    //   'startY': startY,
    //   'endX': endX,
    //   'endY': endY,
    //   'duration': duration,
    // });
    
    debugPrint('Swipe: ($startX, $startY) -> ($endX, $endY) in ${duration}ms');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('被控端'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showSettingsDialog(context),
          ),
        ],
      ),
      body: Consumer<ConnectionService>(
        builder: (context, connectionService, child) {
          final signaling = connectionService.signaling;
          final webrtc = connectionService.webrtc;

          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 状态卡片
                _buildStatusCard(connectionService, signaling, webrtc),
                const SizedBox(height: 32),

                // 配对码显示
                if (signaling.isConnected && !webrtc.isConnected)
                  _buildPairingCodeSection(connectionService),

                // 连接成功提示
                if (webrtc.isConnected)
                  _buildConnectedSection(connectionService),

                const Spacer(),

                // 操作按钮
                _buildActionButtons(connectionService, signaling, webrtc),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusCard(
    ConnectionService connectionService,
    dynamic signaling,
    WebRTCService webrtc,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  signaling.isConnected ? Icons.cloud_done : Icons.cloud_off,
                  color: signaling.isConnected ? Colors.green : Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '服务器连接',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        signaling.isConnected ? '已连接' : '未连接',
                        style: TextStyle(
                          color: signaling.isConnected ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Icon(
                  webrtc.isConnected ? Icons.videocam : Icons.videocam_off,
                  color: webrtc.isConnected ? Colors.blue : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'P2P 连接',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        webrtc.isConnected
                            ? '已连接 - ${connectionService.connectedDevice?.name ?? '未知设备'}'
                            : '等待连接',
                        style: TextStyle(
                          color: webrtc.isConnected ? Colors.blue : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPairingCodeSection(ConnectionService connectionService) {
    return Column(
      children: [
        Text(
          '配对码',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            connectionService.currentPairingCode ?? '------',
            style: TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.bold,
              letterSpacing: 8,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '请在控制端输入此配对码',
          style: TextStyle(
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedSection(ConnectionService connectionService) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green[200]!),
      ),
      child: Column(
        children: [
          Icon(
            Icons.check_circle,
            size: 64,
            color: Colors.green[600],
          ),
          const SizedBox(height: 16),
          Text(
            '已连接',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.green[800],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${connectionService.connectedDevice?.name ?? '未知设备'} 正在控制此设备',
            style: TextStyle(
              color: Colors.green[700],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    ConnectionService connectionService,
    dynamic signaling,
    WebRTCService webrtc,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!signaling.isConnected)
          ElevatedButton.icon(
            onPressed: _startListening,
            icon: const Icon(Icons.refresh),
            label: const Text('重新连接服务器'),
          )
        else if (!webrtc.isConnected)
          ElevatedButton.icon(
            onPressed: () {
              // 生成新的配对码
              setState(() {
                _pairingCode = SignalingService.generatePairingCode();
              });
            },
            icon: const Icon(Icons.refresh),
            label: const Text('刷新配对码'),
          )
        else
          ElevatedButton.icon(
            onPressed: () => connectionService.disconnectAll(),
            icon: const Icon(Icons.stop),
            label: const Text('断开连接'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
      ],
    );
  }

  void _showSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('设备名称'),
              subtitle: Text(
                context.read<ConnectionService>().currentDevice?.name ?? '未知',
              ),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.server),
              title: const Text('服务器地址'),
              subtitle: const Text('wss://your-signaling-server.com/ws'),
              onTap: () {
                // TODO: 修改服务器地址
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context) {
    final controller = TextEditingController(
      text: context.read<ConnectionService>().currentDevice?.name ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改设备名称'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入设备名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                context.read<ConnectionService>().updateDeviceName(controller.text);
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
