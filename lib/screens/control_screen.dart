import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/device.dart';
import '../services/connection_service.dart';
import '../services/signaling_service.dart';

/// 控制端界面 (iOS) - 显示远程 Android 屏幕并发送控制指令
class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  bool _isFullScreen = false;
  double _remoteScreenWidth = 0;
  double _remoteScreenHeight = 0;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _connectToSignaling();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _connectToSignaling() async {
    final connectionService = context.read<ConnectionService>();
    await connectionService.connectToSignaling();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isFullScreen
          ? null
          : AppBar(
              title: const Text('远程控制'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => setState(() => _isFullScreen = true),
                ),
              ],
            ),
      body: Consumer<ConnectionService>(
        builder: (context, connectionService, child) {
          final signaling = connectionService.signaling;
          final webrtc = connectionService.webrtc;

          return Column(
            children: [
              // 连接状态栏
              _buildStatusBar(connectionService, signaling),

              // 远程屏幕显示
              Expanded(
                child: _buildRemoteScreen(webrtc, connectionService),
              ),

              // 底部控制栏
              if (!_isFullScreen) _buildControlBar(connectionService),
            ],
          );
        },
      ),
      floatingActionButton: _isFullScreen
          ? FloatingActionButton.small(
              onPressed: () => setState(() => _isFullScreen = false),
              child: const Icon(Icons.fullscreen_exit),
            )
          : null,
    );
  }

  Widget _buildStatusBar(ConnectionService connectionService, SignalingService signaling) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 信令服务器状态
            _StatusIndicator(
              isActive: signaling.isConnected,
              activeColor: Colors.green,
              inactiveColor: Colors.red,
              label: '服务器',
            ),
            const SizedBox(width: 16),
            // WebRTC 连接状态
            _StatusIndicator(
              isActive: connectionService.webrtc.isConnected,
              activeColor: Colors.blue,
              inactiveColor: Colors.grey,
              label: 'P2P连接',
            ),
            const SizedBox(width: 16),
            // 已连接设备
            if (connectionService.connectedDevice != null)
              Expanded(
                child: Text(
                  '已连接: ${connectionService.connectedDevice!.name}',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteScreen(WebRTCService webrtc, ConnectionService connectionService) {
    if (!webrtc.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!webrtc.isConnected) {
      return _buildDeviceList(connectionService);
    }

    // 显示远程屏幕并处理触摸事件
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapDown: (details) => _handleTouch(
            connectionService,
            'down',
            details.localPosition,
            constraints.biggest,
          ),
          onTapUp: (details) => _handleTouch(
            connectionService,
            'up',
            details.localPosition,
            constraints.biggest,
          ),
          onPanStart: (details) => _handleTouch(
            connectionService,
            'down',
            details.localPosition,
            constraints.biggest,
          ),
          onPanUpdate: (details) => _handleTouch(
            connectionService,
            'move',
            details.localPosition,
            constraints.biggest,
          ),
          onPanEnd: (details) => _handleTouch(
            connectionService,
            'up',
            details.localPosition,
            constraints.biggest,
          ),
          child: Container(
            color: Colors.black,
            child: RTCVideoView(
              webrtc.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDeviceList(ConnectionService connectionService) {
    final devices = connectionService.signaling.discoveredDevices;

    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              '未发现设备',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请确保被控端已启动并连接到同一服务器',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _connectToSignaling,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: device.type == DeviceType.android
                  ? Colors.green[100]
                  : Colors.blue[100],
              child: Icon(
                device.type == DeviceType.android
                    ? Icons.android
                    : Icons.phone_iphone,
                color: device.type == DeviceType.android
                    ? Colors.green
                    : Colors.blue,
              ),
            ),
            title: Text(device.name),
            subtitle: Text('状态: ${device.status.name}'),
            trailing: ElevatedButton(
              onPressed: connectionService.isConnecting
                  ? null
                  : () => connectionService.startPairing(device.id),
              child: connectionService.isConnecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('连接'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlBar(ConnectionService connectionService) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ControlButton(
              icon: Icons.home,
              label: 'Home',
              onPressed: () => _sendKeyEvent(connectionService, 3), // KEYCODE_HOME
            ),
            _ControlButton(
              icon: Icons.arrow_back,
              label: '返回',
              onPressed: () => _sendKeyEvent(connectionService, 4), // KEYCODE_BACK
            ),
            _ControlButton(
              icon: Icons.recent_actors,
              label: '任务',
              onPressed: () => _sendKeyEvent(connectionService, 187), // KEYCODE_APP_SWITCH
            ),
            _ControlButton(
              icon: Icons.power_settings_new,
              label: '电源',
              onPressed: () => _sendKeyEvent(connectionService, 26), // KEYCODE_POWER
            ),
            _ControlButton(
              icon: Icons.volume_up,
              label: '音量+',
              onPressed: () => _sendKeyEvent(connectionService, 24), // KEYCODE_VOLUME_UP
            ),
            _ControlButton(
              icon: Icons.volume_down,
              label: '音量-',
              onPressed: () => _sendKeyEvent(connectionService, 25), // KEYCODE_VOLUME_DOWN
            ),
          ],
        ),
      ),
    );
  }

  void _handleTouch(
    ConnectionService connectionService,
    String action,
    Offset position,
    Size containerSize,
  ) {
    if (!connectionService.webrtc.isConnected) return;

    // 将本地坐标转换为远程设备坐标
    final x = position.dx / containerSize.width;
    final y = position.dy / containerSize.height;

    connectionService.webrtc.sendTouchEvent(
      action: action,
      x: x,
      y: y,
    );
  }

  void _sendKeyEvent(ConnectionService connectionService, int keyCode) {
    if (!connectionService.webrtc.isConnected) return;

    connectionService.webrtc.sendKeyEvent(
      keyCode: keyCode,
      action: 'down',
    );

    // 模拟按键抬起
    Future.delayed(const Duration(milliseconds: 50), () {
      connectionService.webrtc.sendKeyEvent(
        keyCode: keyCode,
        action: 'up',
      );
    });
  }
}

class _StatusIndicator extends StatelessWidget {
  final bool isActive;
  final Color activeColor;
  final Color inactiveColor;
  final String label;

  const _StatusIndicator({
    required this.isActive,
    required this.activeColor,
    required this.inactiveColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive ? activeColor : inactiveColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? activeColor : inactiveColor,
          ),
        ),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
