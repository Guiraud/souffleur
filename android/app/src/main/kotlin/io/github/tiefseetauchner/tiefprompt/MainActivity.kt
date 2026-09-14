package io.github.tiefseetauchner.tiefprompt

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var voiceFeed: VoiceFeed? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val feed = VoiceFeed(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, VoiceFeed.METHOD_CHANNEL).setMethodCallHandler(feed)
        EventChannel(messenger, VoiceFeed.EVENT_CHANNEL).setStreamHandler(feed)
        voiceFeed = feed
    }

    override fun onDestroy() {
        voiceFeed?.stop()
        super.onDestroy()
    }
}
