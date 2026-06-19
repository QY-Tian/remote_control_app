# 远程控制 App

一个跨平台的远程控制应用，支持 iOS 设备控制 Android 设备。

## 功能特性

- **跨平台支持**: 使用 Flutter 开发，一套代码同时支持 iOS 和 Android
- **实时屏幕传输**: 基于 WebRTC 技术，低延迟传输 Android 屏幕画面到 iOS
- **远程触摸控制**: iOS 端触摸操作实时同步到 Android 设备
- **系统按键控制**: 支持 Home、返回、任务切换、电源、音量等系统按键
- **跨网络连接**: 支持不同网络环境下的设备互联（需要信令服务器）
- **设备配对**: 通过配对码机制确保连接安全
- **P2P 直连**: 优先使用 WebRTC P2P 连接，数据不经过服务器中转

## 技术架构

```
┌─────────────────┐      WebRTC DataChannel      ┌─────────────────┐
│   iOS 控制端     │  ◄───── 屏幕画面(H.264) ─────►  │  Android 被控端  │
│  (Flutter App)   │  ◄───── 控制指令(touch) ─────►  │  (Flutter App)   │
└─────────────────┘                            └─────────────────┘
         │                                              │
         │         ┌─────────────────┐                  │
         └────────►│   信令服务器      │◄─────────────────┘
                   │ (WebSocket +      │
                   │  Node.js)         │
                   └─────────────────┘
```

## 项目结构

```
remote_control_app/
├── android/                          # Android 原生代码
│   └── app/src/main/kotlin/.../
│       ├── MainActivity.kt           # 主 Activity
│       ├── RemoteControlPlugin.kt    # 原生插件（触摸注入）
│       └── .../
├── ios/                              # iOS 原生代码
├── lib/                              # Flutter 代码
│   ├── main.dart                     # 应用入口
│   ├── models/
│   │   └── device.dart               # 设备数据模型
│   ├── screens/
│   │   ├── home_screen.dart          # 首页（选择角色）
│   │   ├── control_screen.dart       # 控制端界面
│   │   └── controlled_screen.dart    # 被控端界面
│   ├── services/
│   │   ├── connection_service.dart   # 连接管理
│   │   ├── signaling_service.dart    # 信令服务
│   │   └── webrtc_service.dart       # WebRTC 服务
│   ├── utils/
│   │   └── constants.dart            # 应用常量
│   └── widgets/                      # 自定义组件
├── signaling_server/                 # 信令服务器
│   ├── server.js                     # 主服务器
│   └── package.json
└── pubspec.yaml                      # 依赖配置
```

## 快速开始

### 1. 环境准备

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (>= 3.0.0)
- [Node.js](https://nodejs.org/) (>= 16.0.0，用于信令服务器)
- Android Studio / Xcode
- 一台 Android 设备（被控端）
- 一台 iOS 设备（控制端）

### 2. 安装依赖

```bash
# Flutter 依赖
cd remote_control_app
flutter pub get

# 信令服务器依赖
cd signaling_server
npm install
```

### 3. 启动信令服务器

```bash
cd signaling_server
npm start

# 或使用 PM2 部署到生产环境
npm run pm2:start
```

服务器默认运行在 `ws://localhost:8080`

### 4. 配置服务器地址

修改 `lib/services/signaling_service.dart` 中的默认服务器地址：

```dart
static const String _defaultServerUrl = 'ws://your-server-ip:8080';
```

### 5. 运行应用

**Android 被控端：**
```bash
flutter run -d android
```

**iOS 控制端：**
```bash
flutter run -d ios
```

### 6. 配对连接

1. 在 Android 设备上选择"被控端"
2. 在 iOS 设备上选择"控制端"
3. 两台设备连接到同一个信令服务器
4. iOS 端会显示可连接的设备列表
5. 点击"连接"，输入 Android 端显示的配对码
6. 连接成功后即可远程控制

## Android 被控端配置

### 1. 启用无障碍服务

Android 被控端需要启用无障碍服务才能注入触摸事件：

1. 打开系统设置 -> 无障碍
2. 找到"远程控制"
3. 启用该服务

### 2. 屏幕录制权限

首次连接时，系统会请求屏幕录制权限，请点击"允许"。

### 3. 后台运行

为确保应用能在后台持续运行，建议：
- 关闭电池优化
- 允许后台活动
- 锁定应用（多任务界面下拉锁定）

## 信令服务器部署

### 使用 Docker 部署

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 8080
CMD ["node", "server.js"]
```

```bash
docker build -t remote-control-server .
docker run -d -p 8080:8080 --name remote-control-server remote-control-server
```

### 使用 Nginx 反向代理（HTTPS/WSS）

```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location /ws {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 注意事项

1. **网络要求**: 两台设备都需要能访问互联网（用于 STUN/TURN 服务器）
2. **防火墙**: 确保防火墙允许 WebRTC 所需的 UDP 端口范围（10000-20000）
3. **性能**: 屏幕录制会消耗一定电量和性能，建议连接充电器使用
4. **安全**: 生产环境请配置自己的 TURN 服务器和 HTTPS
5. **兼容性**: Android 5.0+ (API 21+)，iOS 11.0+

## 常见问题

**Q: 为什么无法发现设备？**
A: 请确保两台设备连接到同一个信令服务器，并且网络互通。

**Q: 为什么 P2P 连接失败？**
A: 可能是 NAT 穿透失败，需要配置 TURN 服务器作为中继。

**Q: Android 端触摸不响应？**
A: 请检查无障碍服务是否已启用。

**Q: 画面卡顿？**
A: 可以尝试降低视频分辨率或帧率。

## 许可证

MIT License
