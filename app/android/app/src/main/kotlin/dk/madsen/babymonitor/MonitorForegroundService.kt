package dk.madsen.babymonitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the parent unit connected while the phone sleeps / the screen is off.
 *
 * A foreground service exempts the app's process from Doze/App-Standby, so the
 * main isolate - and the live WebRTC connection running in it - keeps executing
 * and playing the nursery audio through the night. A PARTIAL_WAKE_LOCK keeps the
 * CPU alive so the socket/audio keeps flowing with the screen off. Started when
 * a parent session begins, stopped when it ends (see MainActivity + Dart
 * KeepAliveService).
 */
class MonitorForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Baby Monitor"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Listening for sounds…"
        startAsForeground(title, text)
        acquireWakeLock()
        // Ask the system to recreate us if it ever kills the service.
        return START_STICKY
    }

    private fun startAsForeground(title: String, text: String) {
        createChannel()
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launch ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Monitoring",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the baby monitor connected while the screen is off"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    @android.annotation.SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        // No timeout on purpose: held for the whole monitoring session and
        // released explicitly in onDestroy when the session ends.
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
            // Releasing an already-released lock is harmless.
        }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "monitor_keepalive"
        const val NOTIFICATION_ID = 42
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val WAKELOCK_TAG = "babymonitor:monitor"
    }
}
