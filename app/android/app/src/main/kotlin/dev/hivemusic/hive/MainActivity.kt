package dev.hivemusic.hive

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// AudioServiceActivity keeps one Flutter engine shared with the background
// playback service, so music continues with the screen locked.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ShazamChannel.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
