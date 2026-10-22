package com.specterint.viewvee

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private var multicastLock: WifiManager.MulticastLock? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			"viewvee/audio_monitor",
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"backgroundCamera" -> {
					try {
						check(ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
							ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
							"Camera and microphone permissions are required."
						}
						AudioMonitorForegroundService.start(applicationContext, "transmitter") { error ->
							if (error != null) {
								result.error("foreground_service_failed", error, null)
							} else if (moveTaskToBack(true)) {
								result.success(null)
							} else {
								result.error("background_failed", "Could not move ViewVee to the background.", null)
							}
						}
					} catch (error: RuntimeException) {
						result.error("foreground_service_failed", error.message, null)
					}
				}
				"startForegroundService" -> {
					val role = call.argument<String>("role") ?: "transmitter"
					AudioMonitorForegroundService.start(applicationContext, role)
					result.success(null)
				}
				"stopForegroundService" -> {
					AudioMonitorForegroundService.stop(applicationContext)
					result.success(null)
				}
				"acquireMulticastLock" -> {
					val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
					if (multicastLock?.isHeld != true) {
						multicastLock = wifiManager.createMulticastLock("viewvee-discovery").apply {
							setReferenceCounted(false)
							acquire()
						}
					}
					result.success(null)
				}
				"releaseMulticastLock" -> {
					if (multicastLock?.isHeld == true) multicastLock?.release()
					multicastLock = null
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}
}
