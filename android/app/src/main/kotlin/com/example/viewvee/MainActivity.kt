package com.example.viewvee

import android.content.Context
import android.net.wifi.WifiManager
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
