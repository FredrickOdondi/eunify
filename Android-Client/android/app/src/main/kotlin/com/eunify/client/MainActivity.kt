package com.eunify.client

import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import android.media.session.MediaSessionManager
import android.media.session.MediaController
import android.content.ComponentName
import android.content.Context
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.media.session.PlaybackState

class MainActivity: FlutterFragmentActivity() {
    private val CONTROL_CHANNEL = "com.eunify.client/notification_control"
    private val EVENTS_CHANNEL = "com.eunify.client/notification_events"

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    EunifyNotificationListener.notificationListener = { payload ->
                        eventSink?.success(payload)
                    }
                    // Snappy: Push current song immediately upon connection/listener start
                    EunifyNotificationListener.pushCurrentMediaState(applicationContext)
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    EunifyNotificationListener.notificationListener = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationListenerGranted" -> {
                    val enabledListeners = NotificationManagerCompat.getEnabledListenerPackages(applicationContext)
                    result.success(enabledListeners.contains(applicationContext.packageName))
                }
                "openNotificationListenerSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", "Failed opening settings", e.localizedMessage)
                    }
                }
                "replyToNotification" -> {
                    val notificationId = call.argument<String>("notification_id")
                    val replyText = call.argument<String>("reply_text")
                    if (notificationId != null && replyText != null) {
                        val success = EunifyNotificationListener.sendReply(applicationContext, notificationId, replyText)
                        if (success) {
                            android.widget.Toast.makeText(applicationContext, "Reply sent to app", android.widget.Toast.LENGTH_SHORT).show()
                        } else {
                            android.widget.Toast.makeText(applicationContext, "Reply failed: Action expired or not found", android.widget.Toast.LENGTH_LONG).show()
                        }
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGS", "Missing notification_id or reply_text", null)
                    }
                }
                "controlMedia" -> {
                    val action = call.argument<String>("action")
                    if (action != null) {
                        val success = controlActiveMedia(action)
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGS", "Missing action", null)
                    }
                }
                "refreshMedia" -> {
                    EunifyNotificationListener.pushCurrentMediaState(applicationContext)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun controlActiveMedia(action: String): Boolean {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val keyCode = when (action.uppercase()) {
                "PLAY" -> android.view.KeyEvent.KEYCODE_MEDIA_PLAY
                "PAUSE" -> android.view.KeyEvent.KEYCODE_MEDIA_PAUSE
                "SKIP_FORWARD" -> android.view.KeyEvent.KEYCODE_MEDIA_NEXT
                "SKIP_BACKWARD" -> android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS
                else -> -1
            }

            if (keyCode != -1) {
                // System-wide Media Key Dispatch (Simulates headset button)
                audioManager.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, keyCode))
                audioManager.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, keyCode))
                Log.d("EunifyMedia", "System-wide media key dispatched: $action")
            }
        } catch (e: Exception) {
            Log.e("EunifyMedia", "AudioManager dispatch failed", e)
        }

        // Also try the specific session control as a secondary method
        return EunifyNotificationListener.triggerMediaAction(applicationContext, action)
    }
}
