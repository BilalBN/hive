package dev.hivemusic.hive

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Built without Apple's ShazamKit library: Listen knows songs at home only. */
object ShazamChannel {
    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "hive/shazam").setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(false)
                else -> result.notImplemented()
            }
        }
    }
}
