package com.aether.remote

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

object Cfg {
    fun pin(c: Context): String {
        val p = c.getSharedPreferences("aether_native", 0)
        var pin = p.getString("pin", null)
        if (pin == null) {
            pin = (1000 + SecureRandom().nextInt(9000)).toString()
            p.edit().putString("pin", pin).apply()
        }
        return pin
    }
    fun name(): String = Build.MODEL
}

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aether/tv").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> {
                    val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    result.success(ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
                }
                "pin" -> result.success(Cfg.pin(this))
                "name" -> result.success(Cfg.name())
                "enabled" -> {
                    val s = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
                    result.success(s.contains(packageName + "/" + RemoteService::class.java.name))
                }
                "openSettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
