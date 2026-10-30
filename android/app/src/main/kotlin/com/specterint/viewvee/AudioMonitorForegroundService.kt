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
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class AudioMonitorForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

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
            else -> "Přenos obrazu a zvuku z tohoto zařízení."
        }
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ViewVee je aktivní")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        @Suppress("DEPRECATION")
        val ready = intent?.getParcelableExtra<ResultReceiver>(EXTRA_READY)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, serviceType(role))
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            ready?.send(0, null)
        } catch (error: RuntimeException) {
            ready?.send(1, Bundle().apply { putString("error", error.message) })
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock?.isHeld != true) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "viewvee:audio").apply {
                setReferenceCounted(false)
                acquire()
            }
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
                "Živý přenos ViewVee",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Udržuje přenos obrazu a zvuku na pozadí."
                setShowBadge(false)
            },
        )
    }

    companion object {
        private const val CHANNEL_ID = "viewvee_audio_monitor"
        private const val NOTIFICATION_ID = 4242
        private const val EXTRA_ROLE = "audio_monitor_role"
        private const val EXTRA_READY = "foreground_ready"
        const val ROLE_TRANSMITTER = "transmitter"
        const val ROLE_RECEIVER = "receiver"
        const val ROLE_RECEIVER_TALKBACK = "receiverTalkback"

        fun start(context: Context, role: String, onReady: ((String?) -> Unit)? = null) {
            val intent = Intent(context, AudioMonitorForegroundService::class.java).apply {
                putExtra(EXTRA_ROLE, role)
                if (onReady != null) {
                    putExtra(EXTRA_READY, object : ResultReceiver(Handler(Looper.getMainLooper())) {
                        override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                            onReady(if (resultCode == 0) null else resultData?.getString("error")
                                ?: "Foreground service could not start.")
                        }
                    })
                }
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
