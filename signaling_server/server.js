const WebSocket = require('ws');
const http = require('http');
const crypto = require('crypto');

/**
 * 信令服务器
 * 
 * 功能：
 * 1. 设备注册和发现
 * 2. 配对请求/响应转发
 * 3. WebRTC SDP 交换转发
 * 4. ICE Candidate 转发
 * 5. 心跳检测
 * 
 * 部署：
 * - 开发环境: node server.js
 * - 生产环境: 使用 PM2 或 Docker 部署
 * - 需要 HTTPS/WSS 以支持 WebRTC
 */

const PORT = process.env.PORT || 8080;
const HEARTBEAT_INTERVAL = 30000; // 30秒心跳检测
const HEARTBEAT_TIMEOUT = 60000;  // 60秒超时断开

// 存储连接的设备
const devices = new Map(); // deviceId -> { ws, info, lastHeartbeat }

// 创建 HTTP 服务器
const server = http.createServer((req, res) => {
  // 简单的健康检查端点
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      devices: devices.size,
      uptime: process.uptime(),
    }));
    return;
  }

  res.writeHead(404);
  res.end('Not Found');
});

// 创建 WebSocket 服务器
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws, req) => {
  console.log(`新连接: ${req.socket.remoteAddress}`);

  let deviceId = null;

  ws.on('message', (data) => {
    try {
      const message = JSON.parse(data);
      handleMessage(ws, message, deviceId);

      // 如果是注册消息，更新 deviceId
      if (message.type === 'register') {
        deviceId = message.deviceId;
      }
    } catch (error) {
      console.error('消息解析错误:', error);
      sendError(ws, 'Invalid message format');
    }
  });

  ws.on('close', () => {
    if (deviceId) {
      removeDevice(deviceId);
    }
    console.log(`连接关闭: ${deviceId || 'unknown'}`);
  });

  ws.on('error', (error) => {
    console.error('WebSocket 错误:', error);
  });

  // 发送欢迎消息
  send(ws, { type: 'connected', message: 'Signaling server connected' });
});

/**
 * 处理收到的消息
 */
function handleMessage(ws, message, currentDeviceId) {
  const { type } = message;

  switch (type) {
    case 'register':
      handleRegister(ws, message);
      break;

    case 'unregister':
      if (currentDeviceId) {
        removeDevice(currentDeviceId);
      }
      break;

    case 'ping':
      handlePing(ws, currentDeviceId);
      break;

    case 'pair_request':
      forwardMessage(message, message.to);
      break;

    case 'pair_response':
      forwardMessage(message, message.to);
      break;

    case 'offer':
      forwardMessage(message, message.to);
      break;

    case 'answer':
      forwardMessage(message, message.to);
      break;

    case 'ice_candidate':
      forwardMessage(message, message.to);
      break;

    case 'disconnect':
      forwardMessage(message, message.to);
      break;

    default:
      sendError(ws, `Unknown message type: ${type}`);
  }
}

/**
 * 处理设备注册
 */
function handleRegister(ws, message) {
  const { deviceId, deviceName, role, deviceType } = message;

  if (!deviceId || !deviceName || !role) {
    sendError(ws, 'Missing required fields');
    return;
  }

  // 如果设备已存在，先移除旧连接
  if (devices.has(deviceId)) {
    const oldDevice = devices.get(deviceId);
    if (oldDevice.ws !== ws && oldDevice.ws.readyState === WebSocket.OPEN) {
      oldDevice.ws.close();
    }
  }

  // 存储设备信息
  devices.set(deviceId, {
    ws,
    info: {
      id: deviceId,
      name: deviceName,
      role,
      type: deviceType || 'unknown',
      status: 'online',
      lastSeen: new Date().toISOString(),
    },
    lastHeartbeat: Date.now(),
  });

  console.log(`设备注册: ${deviceName} (${deviceId}) - ${role}`);

  // 发送确认
  send(ws, { type: 'registered', deviceId });

  // 广播设备列表更新
  broadcastDeviceList();
}

/**
 * 处理心跳
 */
function handlePing(ws, deviceId) {
  send(ws, { type: 'pong' });

  if (deviceId && devices.has(deviceId)) {
    const device = devices.get(deviceId);
    device.lastHeartbeat = Date.now();
    device.info.lastSeen = new Date().toISOString();
  }
}

/**
 * 转发消息到目标设备
 */
function forwardMessage(message, targetDeviceId) {
  const targetDevice = devices.get(targetDeviceId);

  if (!targetDevice) {
    console.log(`目标设备不存在: ${targetDeviceId}`);
    return;
  }

  if (targetDevice.ws.readyState !== WebSocket.OPEN) {
    console.log(`目标设备连接已关闭: ${targetDeviceId}`);
    removeDevice(targetDeviceId);
    return;
  }

  send(targetDevice.ws, message);
}

/**
 * 移除设备
 */
function removeDevice(deviceId) {
  if (devices.has(deviceId)) {
    devices.delete(deviceId);
    console.log(`设备移除: ${deviceId}`);
    broadcastDeviceList();
  }
}

/**
 * 广播设备列表给所有连接
 */
function broadcastDeviceList() {
  const deviceList = Array.from(devices.values()).map(d => d.info);
  const message = {
    type: 'device_list',
    devices: deviceList,
  };

  broadcast(message);
}

/**
 * 广播消息给所有设备
 */
function broadcast(message) {
  const data = JSON.stringify(message);
  devices.forEach((device, deviceId) => {
    if (device.ws.readyState === WebSocket.OPEN) {
      device.ws.send(data);
    } else {
      removeDevice(deviceId);
    }
  });
}

/**
 * 发送消息
 */
function send(ws, message) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

/**
 * 发送错误消息
 */
function sendError(ws, errorMessage) {
  send(ws, { type: 'error', message: errorMessage });
}

/**
 * 心跳检测 - 清理超时设备
 */
setInterval(() => {
  const now = Date.now();
  const toRemove = [];

  devices.forEach((device, deviceId) => {
    if (now - device.lastHeartbeat > HEARTBEAT_TIMEOUT) {
      toRemove.push(deviceId);
    }
  });

  toRemove.forEach(deviceId => {
    console.log(`设备心跳超时: ${deviceId}`);
    removeDevice(deviceId);
  });
}, HEARTBEAT_INTERVAL);

// 启动服务器
server.listen(PORT, () => {
  console.log(`信令服务器启动: http://localhost:${PORT}`);
  console.log(`WebSocket: ws://localhost:${PORT}`);
});

// 优雅关闭
process.on('SIGTERM', () => {
  console.log('SIGTERM 收到，关闭服务器...');
  wss.close(() => {
    server.close(() => {
      process.exit(0);
    });
  });
});

process.on('SIGINT', () => {
  console.log('SIGINT 收到，关闭服务器...');
  wss.close(() => {
    server.close(() => {
      process.exit(0);
    });
  });
});
