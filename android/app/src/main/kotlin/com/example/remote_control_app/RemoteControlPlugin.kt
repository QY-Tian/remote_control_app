package com.example.remote_control_app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Android 原生插件 - 远程控制功能
 * 
 * 功能：
 * 1. 屏幕录制 (MediaProjection)
 * 2. 触摸事件注入 (AccessibilityService)
 * 3. 按键事件注入
 * 4. 滑动手势注入
 */
class RemoteControlPlugin : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.example.remote_control/control"
        var instance: RemoteControlPlugin? = null
        var accessibilityService: RemoteControlAccessibilityService? = null

        fun registerWith(registrar: PluginRegistry.Registrar) {
            val channel = MethodChannel(registrar.messenger(), CHANNEL_NAME)
            instance = RemoteControlPlugin()
            channel.setMethodCallHandler(instance)
        }

        fun init(flutterEngine: FlutterEngine, context: Context) {
            val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            instance = RemoteControlPlugin()
            instance?.context = context
            channel.setMethodCallHandler(instance)
        }
    }

    private var context: Context? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "injectTouch" -> handleInjectTouch(call, result)
            "injectKey" -> handleInjectKey(call, result)
            "injectSwipe" -> handleInjectSwipe(call, result)
            "startScreenCapture" -> handleStartScreenCapture(result)
            "stopScreenCapture" -> handleStopScreenCapture(result)
            "isAccessibilityEnabled" -> handleIsAccessibilityEnabled(result)
            "requestAccessibility" -> handleRequestAccessibility(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 注入触摸事件
     * 
     * 参数：
     * - action: String ("down", "move", "up")
     * - x: Double (0.0 - 1.0, 相对坐标)
     * - y: Double (0.0 - 1.0, 相对坐标)
     * - pressure: Double (可选)
     */
    private fun handleInjectTouch(call: MethodCall, result: MethodChannel.Result) {
        val action = call.argument<String>("action")
        val x = call.argument<Double>("x") ?: 0.0
        val y = call.argument<Double>("y") ?: 0.0

        if (action == null) {
            result.error("INVALID_ARGUMENT", "Missing action parameter", null)
            return
        }

        val service = accessibilityService
        if (service == null) {
            result.error("SERVICE_NOT_AVAILABLE", "AccessibilityService not running", null)
            return
        }

        // 将相对坐标转换为绝对坐标
        val displayMetrics = context?.resources?.displayMetrics
        val screenWidth = displayMetrics?.widthPixels ?: 1080
        val screenHeight = displayMetrics?.heightPixels ?: 1920

        val absoluteX = (x * screenWidth).toFloat()
        val absoluteY = (y * screenHeight).toFloat()

        // 创建手势
        val path = Path()
        path.moveTo(absoluteX, absoluteY)

        val gestureBuilder = GestureDescription.Builder()
        
        when (action) {
            "down" -> {
                gestureBuilder.addStroke(
                    GestureDescription.StrokeDescription(path, 0, 100)
                )
            }
            "move" -> {
                // 移动需要持续的手势，这里简化处理
                gestureBuilder.addStroke(
                    GestureDescription.StrokeDescription(path, 0, 50)
                )
            }
            "up" -> {
                gestureBuilder.addStroke(
                    GestureDescription.StrokeDescription(path, 0, 10)
                )
            }
            else -> {
                result.error("INVALID_ACTION", "Unknown action: $action", null)
                return
            }
        }

        val dispatched = service.dispatchGesture(
            gestureBuilder.build(),
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    result.success(true)
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    result.error("GESTURE_CANCELLED", "Gesture was cancelled", null)
                }
            },
            null
        )

        if (!dispatched) {
            result.error("DISPATCH_FAILED", "Failed to dispatch gesture", null)
        }
    }

    /**
     * 注入按键事件
     * 
     * 参数：
     * - keyCode: Int (Android KeyEvent keyCode)
     * - action: String ("down", "up")
     */
    private fun handleInjectKey(call: MethodCall, result: MethodChannel.Result) {
        val keyCode = call.argument<Int>("keyCode")
        val action = call.argument<String>("action")

        if (keyCode == null || action == null) {
            result.error("INVALID_ARGUMENT", "Missing keyCode or action", null)
            return
        }

        // AccessibilityService 不能直接注入按键事件
        // 需要通过 performGlobalAction 来模拟一些系统按键
        val service = accessibilityService
        if (service == null) {
            result.error("SERVICE_NOT_AVAILABLE", "AccessibilityService not running", null)
            return
        }

        val success = when (keyCode) {
            3 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME) // KEYCODE_HOME
            4 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) // KEYCODE_BACK
            187 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS) // KEYCODE_APP_SWITCH
            26 -> service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_POWER_DIALOG) // KEYCODE_POWER
            24 -> { // KEYCODE_VOLUME_UP
                // 需要通过 AudioManager
                val audioManager = context?.getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager
                audioManager?.adjustStreamVolume(
                    android.media.AudioManager.STREAM_MUSIC,
                    android.media.AudioManager.ADJUST_RAISE,
                    0
                )
                true
            }
            25 -> { // KEYCODE_VOLUME_DOWN
                val audioManager = context?.getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager
                audioManager?.adjustStreamVolume(
                    android.media.AudioManager.STREAM_MUSIC,
                    android.media.AudioManager.ADJUST_LOWER,
                    0
                )
                true
            }
            else -> {
                result.error("UNSUPPORTED_KEY", "Key code $keyCode is not supported", null)
                return
            }
        }

        result.success(success)
    }

    /**
     * 注入滑动手势
     * 
     * 参数：
     * - startX: Double (0.0 - 1.0)
     * - startY: Double (0.0 - 1.0)
     * - endX: Double (0.0 - 1.0)
     * - endY: Double (0.0 - 1.0)
     * - duration: Int (毫秒)
     */
    private fun handleInjectSwipe(call: MethodCall, result: MethodChannel.Result) {
        val startX = call.argument<Double>("startX") ?: 0.0
        val startY = call.argument<Double>("startY") ?: 0.0
        val endX = call.argument<Double>("endX") ?: 0.0
        val endY = call.argument<Double>("endY") ?: 0.0
        val duration = call.argument<Int>("duration") ?: 300

        val service = accessibilityService
        if (service == null) {
            result.error("SERVICE_NOT_AVAILABLE", "AccessibilityService not running", null)
            return
        }

        // 将相对坐标转换为绝对坐标
        val displayMetrics = context?.resources?.displayMetrics
        val screenWidth = displayMetrics?.widthPixels ?: 1080
        val screenHeight = displayMetrics?.heightPixels ?: 1920

        val absoluteStartX = (startX * screenWidth).toFloat()
        val absoluteStartY = (startY * screenHeight).toFloat()
        val absoluteEndX = (endX * screenWidth).toFloat()
        val absoluteEndY = (endY * screenHeight).toFloat()

        // 创建滑动手势
        val path = Path()
        path.moveTo(absoluteStartX, absoluteStartY)
        path.lineTo(absoluteEndX, absoluteEndY)

        val gestureBuilder = GestureDescription.Builder()
        gestureBuilder.addStroke(
            GestureDescription.StrokeDescription(path, 0, duration.toLong())
        )

        val dispatched = service.dispatchGesture(
            gestureBuilder.build(),
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    result.success(true)
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    result.error("GESTURE_CANCELLED", "Gesture was cancelled", null)
                }
            },
            null
        )

        if (!dispatched) {
            result.error("DISPATCH_FAILED", "Failed to dispatch gesture", null)
        }
    }

    /**
     * 开始屏幕录制
     */
    private fun handleStartScreenCapture(result: MethodChannel.Result) {
        // 屏幕录制由 Flutter 层的 flutter_webrtc 处理
        // 这里只需要确保 MediaProjection 权限已获取
        result.success(true)
    }

    /**
     * 停止屏幕录制
     */
    private fun handleStopScreenCapture(result: MethodChannel.Result) {
        result.success(true)
    }

    /**
     * 检查无障碍服务是否启用
     */
    private fun handleIsAccessibilityEnabled(result: MethodChannel.Result) {
        val enabled = accessibilityService != null
        result.success(enabled)
    }

    /**
     * 请求启用无障碍服务
     */
    private fun handleRequestAccessibility(result: MethodChannel.Result) {
        // 打开无障碍服务设置页面
        val intent = android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        context?.startActivity(intent)
        result.success(true)
    }
}

/**
 * 无障碍服务 - 用于注入触摸和按键事件
 */
class RemoteControlAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 不需要处理事件
    }

    override fun onInterrupt() {
        // 服务被中断
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        RemoteControlPlugin.accessibilityService = this
        
        // 配置服务
        serviceInfo = serviceInfo.apply {
            // 设置可以执行的手势类型
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Android 8.0+ 支持更多手势
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        RemoteControlPlugin.accessibilityService = null
    }
}
