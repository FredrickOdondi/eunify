package com.eunify.client

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.ComponentName
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Icon
import android.util.Base64
import android.util.Log
import android.media.session.MediaSession
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.media.session.MediaSessionManager
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class EunifyNotificationListener : NotificationListenerService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaManager: MediaSessionManager? = null
    
    private val progressRunnable = object : Runnable {
        override fun run() {
            pushCurrentMediaState(applicationContext)
            mainHandler.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        mediaManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        setupActiveSessionsListener()
        mainHandler.post(progressRunnable) // Start heartbeat
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(progressRunnable)
        super.onDestroy()
    }

    private fun setupActiveSessionsListener() {
        try {
            val componentName = ComponentName(this, EunifyNotificationListener::class.java)
            mediaManager?.addOnActiveSessionsChangedListener({
                Log.d("EunifyMedia", "Active sessions changed! Pushing update...")
                pushCurrentMediaState(applicationContext)
            }, componentName)
        } catch (e: Exception) {
            Log.e("EunifyMedia", "Failed to setup sessions listener", e)
        }
    }

    companion object {
        val cachedActions = ConcurrentHashMap<String, ReplyAction>()
        val cachedMediaActions = ConcurrentHashMap<String, Map<String, PendingIntent>>()
        var notificationListener: ((Map<String, Any>) -> Unit)? = null
        private var lastPushedMetadata: String = ""

        fun pushCurrentMediaState(context: Context) {
            try {
                val mediaManager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                val componentName = ComponentName(context, EunifyNotificationListener::class.java)
                val controllers = mediaManager.getActiveSessions(componentName)
                
                if (controllers.isNotEmpty()) {
                    val controller = controllers[0]
                    val metadata = controller.metadata
                    val pbState = controller.playbackState
                    
                    if (metadata != null && pbState != null) {
                        val title = metadata.getString(android.media.MediaMetadata.METADATA_KEY_TITLE) ?: "Unknown"
                        val artist = metadata.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST) ?: "Unknown"
                        val duration = metadata.getLong(android.media.MediaMetadata.METADATA_KEY_DURATION)
                        val position = pbState.position
                        val isPlaying = (pbState.state == PlaybackState.STATE_PLAYING)
                        
                        // Deduplicate metadata but allow position to flow
                        val metadataKey = "$title-$artist-$isPlaying-$duration"
                        val positionKey = "$metadataKey-${position / 1000}" // Sync every second, not every millisecond
                        
                        if (positionKey == lastPushedMetadata) return
                        lastPushedMetadata = positionKey

                        val payload = mutableMapOf<String, Any>(
                            "is_media" to true,
                            "title" to title,
                            "body" to artist,
                            "app_name" to controller.packageName,
                            "is_playing" to isPlaying,
                            "duration" to duration.toDouble(),
                            "position" to position.toDouble(),
                            "timestamp" to System.currentTimeMillis()
                        )

                        val bitmap = metadata.getBitmap(android.media.MediaMetadata.METADATA_KEY_ALBUM_ART)
                            ?: metadata.getBitmap(android.media.MediaMetadata.METADATA_KEY_ART)
                        
                        if (bitmap != null) {
                            val outputStream = ByteArrayOutputStream()
                            val scaled = Bitmap.createScaledBitmap(bitmap, 120, 120, true)
                            scaled.compress(Bitmap.CompressFormat.JPEG, 50, outputStream)
                            val base64Art = Base64.encodeToString(outputStream.toByteArray(), Base64.NO_WRAP)
                            payload["album_art"] = "data:image/jpeg;base64,$base64Art"
                        }

                        notificationListener?.invoke(payload)
                    }
                }
            } catch (e: Exception) {
                Log.e("EunifyMedia", "Error in proactive push", e)
            }
        }

        fun triggerMediaAction(context: Context, action: String): Boolean {
            val sessions = (context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager)
                .getActiveSessions(ComponentName(context, EunifyNotificationListener::class.java))
            
            if (sessions.isEmpty()) return false
            
            var anyExecuted = false
            for (controller in sessions) {
                val packageName = controller.packageName
                
                // PRIORITY 1: Hijack notification button (most reliable)
                val actions = cachedMediaActions[packageName]
                if (actions != null && actions.containsKey(action.uppercase())) {
                    try {
                        actions[action.uppercase()]?.send()
                        Log.d("EunifyMedia", "Successfully hijacked notification button for $action on $packageName")
                        anyExecuted = true
                        continue // Move to next session or finish
                    } catch (e: Exception) {
                        Log.e("EunifyMedia", "Failed to hijack notification button", e)
                    }
                }

                // PRIORITY 2: Transport Controls fallback
                try {
                    when (action.uppercase()) {
                        "PLAY" -> controller.transportControls.play()
                        "PAUSE" -> controller.transportControls.pause()
                        "SKIP_FORWARD" -> controller.transportControls.skipToNext()
                        "SKIP_BACKWARD" -> controller.transportControls.skipToPrevious()
                    }
                    Log.d("EunifyMedia", "Dispatched transport command $action to $packageName")
                    anyExecuted = true
                } catch (e: Exception) {
                    Log.e("EunifyMedia", "Transport control failed for $packageName", e)
                }
            }
            return anyExecuted
        }

        fun sendReply(context: Context, notificationId: String, replyText: String): Boolean {
            Log.d("EunifyNotif", "Attempting to send reply for $notificationId: $replyText")
            val action = cachedActions[notificationId] ?: run {
                Log.e("EunifyNotif", "No cached action found for $notificationId")
                return false
            }
            return try {
                val intent = Intent()
                val bundle = Bundle()
                bundle.putCharSequence(action.remoteInput.resultKey, replyText)
                RemoteInput.addResultsToIntent(arrayOf(action.remoteInput), intent, bundle)
                
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                }
                
                action.pendingIntent.send(context, 0, intent)
                Log.d("EunifyNotif", "Reply sent successfully for $notificationId")
                true
            } catch (e: Exception) {
                Log.e("EunifyNotif", "Error sending reply for $notificationId", e)
                false
            }
        }
    }

    data class ReplyAction(
        val pendingIntent: PendingIntent,
        val remoteInput: RemoteInput
    )

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        if (sbn.isOngoing && !extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) {
            return
        }
        if (sbn.packageName == packageName) return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        if (title.isBlank() && text.isBlank() && !extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) {
            return
        }

        val notificationId = sbn.key
        var canReply = false

        val actions = notification.actions
        if (actions != null) {
            val sortedActions = actions.sortedByDescending { 
                it.title?.toString()?.lowercase()?.contains("reply") == true
            }
            
            for (action in sortedActions) {
                val remoteInputs = action.remoteInputs
                if (remoteInputs != null && remoteInputs.isNotEmpty()) {
                    val remoteInput = remoteInputs[0]
                    val pendingIntent = action.actionIntent
                    if (pendingIntent != null) {
                        cachedActions[notificationId] = ReplyAction(pendingIntent, remoteInput)
                        canReply = true
                        break
                    }
                }
            }
        }

        if (cachedActions.size > 50) {
            val keysToRemove = cachedActions.keys.toList().take(10)
            keysToRemove.forEach { cachedActions.remove(it) }
        }

        val appName = try {
            val pm = packageManager
            val ai = pm.getApplicationInfo(sbn.packageName, 0)
            pm.getApplicationLabel(ai).toString()
        } catch (e: Exception) {
            sbn.packageName
        }

        val payload = mutableMapOf<String, Any>(
            "notification_id" to notificationId,
            "package_name" to sbn.packageName,
            "app_name" to appName,
            "title" to title,
            "body" to text,
            "can_reply" to canReply,
            "timestamp" to System.currentTimeMillis()
        )

        try {
            if (notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) {
                payload["is_media"] = true
                
                // Direct Notification Action Hijacking: Cache buttons for direct execution
                val mediaActions = mutableMapOf<String, PendingIntent>()
                notification.actions?.forEach { action ->
                    val titleStr = action.title?.toString()?.lowercase() ?: ""
                    if (titleStr.contains("pause")) mediaActions["PAUSE"] = action.actionIntent
                    else if (titleStr.contains("play")) mediaActions["PLAY"] = action.actionIntent
                    else if (titleStr.contains("next") || titleStr.contains("skip")) mediaActions["SKIP_FORWARD"] = action.actionIntent
                    else if (titleStr.contains("prev") || titleStr.contains("back")) mediaActions["SKIP_BACKWARD"] = action.actionIntent
                }
                if (mediaActions.isNotEmpty()) {
                    cachedMediaActions[sbn.packageName] = mediaActions
                }
                try {
                    val token = extras.getParcelable<MediaSession.Token>(Notification.EXTRA_MEDIA_SESSION)
                    if (token != null) {
                        val controller = MediaController(applicationContext, token)
                        val pbState = controller.playbackState
                        if (pbState != null) {
                            payload["is_playing"] = pbState.state == PlaybackState.STATE_PLAYING
                        }
                    }
                } catch (e: Exception) {
                    Log.w("EunifyNotif", "Could not extract playback state", e)
                }
                
                val iconObj = extras.get(Notification.EXTRA_LARGE_ICON)
                if (iconObj != null) {
                    try {
                        val bitmap = when (iconObj) {
                            is Bitmap -> iconObj
                            is Icon -> {
                               val drawable = iconObj.loadDrawable(applicationContext)
                               if (drawable is BitmapDrawable) drawable.bitmap else null
                            }
                            else -> null
                        }
                        
                        if (bitmap != null) {
                            val outputStream = ByteArrayOutputStream()
                            val scaled = Bitmap.createScaledBitmap(bitmap, 128, 128, true)
                            scaled.compress(Bitmap.CompressFormat.JPEG, 60, outputStream)
                            val base64Art = Base64.encodeToString(outputStream.toByteArray(), Base64.NO_WRAP)
                            payload["album_art"] = "data:image/jpeg;base64,$base64Art"
                        }
                    } catch (e: Exception) {
                        Log.e("EunifyNotif", "Failed to extract album art", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("EunifyNotif", "Media detection error", e)
        }

        mainHandler.post {
            notificationListener?.invoke(payload)
        }
    }
}
