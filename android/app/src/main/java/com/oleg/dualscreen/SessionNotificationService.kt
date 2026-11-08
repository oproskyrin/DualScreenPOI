package com.oleg.dualscreen

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground lifetime for the actual Mac socket session owned by MainActivity.
 * No sockets, endpoint extras, saved sessions, boot receiver or sticky restart here.
 * All access to [sessions] is on the process main thread.
 *
 * connectedDevice covers interaction with an external device over a network;
 * this receiver does not capture/project the Android screen via MediaProjection.
 * Requirements: developer.android.com/develop/background-work/services/fgs/service-types#connected-device
 */
class SessionNotificationService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val updates = SessionNotificationUpdates(UiStrings { id, args -> localizedContext().getString(id, *args) })
    private var promoted = false
    private var notificationsVisible = false
    private val manager get() = getSystemService(NotificationManager::class.java)
    private val refresh = object : Runnable {
        override fun run() {
            val status = sessions.current
            if (status == null) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                val enabled = manager.areNotificationsEnabled() &&
                    manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
                val changed = if (enabled) updates.shouldPost(status, SystemClock.elapsedRealtime()) else false
                if (enabled && (changed || !notificationsVisible)) {
                    manager.notify(NOTIFICATION_ID, notification(status))
                }
                notificationsVisible = enabled
            } else {
                notificationsVisible = false
            }
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, localizedContext().getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW).apply {
            description = localizedContext().getString(R.string.notification_channel_note)
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A delayed start after cancellation or a process restart must never invent a session.
        val status = sessions.current
        if (status == null) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (!promoted) {
            try {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(status),
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0)
                promoted = true
                if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                    notificationsVisible = manager.areNotificationsEnabled() &&
                        manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
                    if (notificationsVisible) updates.shouldPost(status, SystemClock.elapsedRealtime())
                }
            } catch (e: RuntimeException) {
                Log.w("DualScreen", "Cannot promote Mac session service", e)
                Toast.makeText(this, localizedContext().getString(R.string.background_denied), Toast.LENGTH_LONG).show()
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
        }
        handler.removeCallbacks(refresh)
        handler.post(refresh)
        return START_NOT_STICKY
    }

    // Services need the per-app locale explicitly on Android 12 and earlier.
    private fun localizedContext() = androidx.core.content.ContextCompat.getContextForLanguage(this)

    private fun notification(status: SessionNotificationStatus): Notification {
        // Explicit immutable activity PendingIntent, no autoconnect/addr extras. singleTask
        // returns to the existing session; a stale tap can only open the home screen.
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).setAction(ACTION_OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val context = localizedContext()
        val strings = UiStrings { id, args -> context.getString(id, *args) }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_dualscreen)
            .setContentTitle(status.title(strings))
            .setContentText(status.detail(strings).replace("\n", " · "))
            .setStyle(NotificationCompat.BigTextStyle().bigText(status.detail(strings)))
            .setContentIntent(open)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_OPEN = "com.oleg.dualscreen.OPEN_SESSION"
        const val CHANNEL_ID = "mac_session"
        private const val NOTIFICATION_ID = 7381
        val sessions = SessionNotificationStore()
    }
}
