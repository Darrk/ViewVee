package com.specterint.viewvee

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class AudioMonitorForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val role = intent?.getStringExtra(EXTRA_ROLE) ?: ROLE_TRANSMITTER
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val text = when (role) {
            ROLE_RECEIVER -> "Poslouchání zvuku z kamery."
            ROLE_RECEIVER_TALKBACK -> "Poslouchání a obousměrný zvuk."
            else -> "Přenos zvuku z tohoto zařízení."
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Viewvee je aktivní")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, serviceType(role))
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    /**
     * Declares only what each role really uses: the camera phone captures
     * camera + microphone, the viewer plays the stream back and adds the
     * microphone only for talkback. Types whose runtime permission is missing
     * are dropped, since Android 14+ throws SecurityException for them.
     */
    private fun serviceType(role: String): Int {
        var type = when (role) {
            ROLE_RECEIVER -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            ROLE_RECEIVER_TALKBACK ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            else ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (!isGranted(Manifest.permission.CAMERA)) {
            type = type and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA.inv()
        }
        if (!isGranted(Manifest.permission.RECORD_AUDIO)) {
            type = type and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE.inv()
        }
        // Must stay non-zero for startForeground; playback needs no permission.
        return if (type == 0) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else type
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) ==
            PackageManager.PERMISSION_GRANTED

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Živý přenos Viewvee",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Udržuje zvukový přenos při vypnuté obrazovce."
                setShowBadge(false)
            },
        )
    }

    companion object {
        private const val CHANNEL_ID = "viewvee_audio_monitor"
        private const val NOTIFICATION_ID = 4242
        private const val EXTRA_ROLE = "audio_monitor_role"
        const val ROLE_TRANSMITTER = "transmitter"
        const val ROLE_RECEIVER = "receiver"
        const val ROLE_RECEIVER_TALKBACK = "receiverTalkback"

        fun start(context: Context, role: String) {
            val intent = Intent(context, AudioMonitorForegroundService::class.java).apply {
                putExtra(EXTRA_ROLE, role)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AudioMonitorForegroundService::class.java))
        }
    }
}
