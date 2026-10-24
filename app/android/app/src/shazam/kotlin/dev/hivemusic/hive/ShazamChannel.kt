package dev.hivemusic.hive

import android.content.Context
import com.shazam.shazamkit.AudioSampleRateInHz
import com.shazam.shazamkit.DeveloperToken
import com.shazam.shazamkit.DeveloperTokenProvider
import com.shazam.shazamkit.MatchResult
import com.shazam.shazamkit.ShazamKit
import com.shazam.shazamkit.ShazamKitResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Shazam for songs that aren't at home (M5), with Apple's ShazamKit library
 * (app/android/app/libs/shazamkit-android-release.aar). Listen sends the last
 * seconds of sound it heard and an hour-long token made at home; only a
 * fingerprint of the sound goes to Apple.
 */
object ShazamChannel {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "hive/shazam").setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(true)
                "match" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    val rate = call.argument<Int>("rate") ?: 16000
                    val token = call.argument<String>("token")
                    if (pcm == null || token == null) {
                        result.error("bad", "Sound and token are needed", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            result.success(withContext(Dispatchers.Default) { match(pcm, rate, token) })
                        } catch (e: Exception) {
                            result.error("shazam", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private suspend fun match(pcm: ByteArray, rate: Int, token: String): Map<String, String>? {
        val sampleRate = when (rate) {
            48000 -> AudioSampleRateInHz.SAMPLE_RATE_48000
            44100 -> AudioSampleRateInHz.SAMPLE_RATE_44100
            32000 -> AudioSampleRateInHz.SAMPLE_RATE_32000
            else -> AudioSampleRateInHz.SAMPLE_RATE_16000
        }
        val provider = object : DeveloperTokenProvider {
            override fun provideDeveloperToken() = DeveloperToken(token)
        }
        val catalog = ShazamKit.createShazamCatalog(provider)
        val generator = when (val g = ShazamKit.createSignatureGenerator(sampleRate)) {
            is ShazamKitResult.Success -> g.data
            is ShazamKitResult.Failure -> throw IllegalStateException(g.reason.message)
        }
        generator.append(pcm, pcm.size, System.currentTimeMillis())
        val signature = generator.generateSignature()
        val session = when (val s = ShazamKit.createSession(catalog)) {
            is ShazamKitResult.Success -> s.data
            is ShazamKitResult.Failure -> throw IllegalStateException(s.reason.message)
        }
        return when (val r = session.match(signature)) {
            is MatchResult.Match -> r.matchedMediaItems.firstOrNull()?.let { item ->
                val title = item.title ?: return@let null
                buildMap {
                    put("title", title)
                    item.artist?.let { put("artist", it) }
                }
            }
            is MatchResult.NoMatch -> null
            is MatchResult.Error -> throw IllegalStateException(r.exception.message)
        }
    }
}
