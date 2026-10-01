package io.github.tiefseetauchner.tiefprompt

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Speech recognition fed with the app's own microphone capture (Android 13+,
 * RecognizerIntent.EXTRA_AUDIO_SOURCE).
 *
 * With a plain SpeechRecognizer the recognition service (another app) opens
 * the microphone itself, and Android silences it while the camera records
 * sound. Here the app is the only one capturing: the service reads PCM from a
 * pipe, so there is nothing left for Android to silence.
 *
 * When a model for the locale is installed on the device, recognition runs
 * offline (no network needed); otherwise it runs online, and falls back to it
 * whenever offline recognition turns out unusable.
 */
class VoiceFeed(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    RecognitionListener {

    companion object {
        const val METHOD_CHANNEL = "souffleur/voice_feed"
        const val EVENT_CHANNEL = "souffleur/voice_feed/events"
        private const val TAG = "VoiceFeed"
        private const val SAMPLE_RATE = 16000

        // 100 ms of 16-bit mono PCM.
        private const val CHUNK_BYTES = SAMPLE_RATE / 10 * 2

        private const val SUPPORT_CHECK_TIMEOUT_MS = 3000L

        // Offline recognition that stays silent through this much speech
        // (chunks above LOUD_LEVEL, 100 ms each) is considered unusable.
        private const val LOUD_LEVEL = 0.35
        private const val LOUD_CHUNKS_BEFORE_FALLBACK = 60

        private val OFFLINE_FAILURES = setOf(
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE,
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
        )
    }

    /** OFFLINE: default service preferring its on-device model; ON_DEVICE: on-device service. */
    private enum class Engine(val label: String) {
        ONLINE("online"),
        OFFLINE("offline"),
        ON_DEVICE("offline"),
    }

    private data class Support(val installed: Boolean, val downloadable: Boolean)

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var locale = "fr-FR"

    private var preferOffline = true
    // Set once offline recognition failed, so later starts go online directly.
    private var offlineFailed = false
    @Volatile private var engine = Engine.ONLINE
    @Volatile private var loudChunksWithoutResult = 0

    @Volatile private var running = false
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null

    // Current session's pipe. The read end is handed to the recognition
    // service; we keep it open until the session is replaced.
    private var pipeIn: ParcelFileDescriptor? = null
    @Volatile private var pipeOut: ParcelFileDescriptor.AutoCloseOutputStream? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    SpeechRecognizer.isRecognitionAvailable(context)
            )
            "start" -> {
                locale = call.argument<String>("locale") ?: "fr-FR"
                preferOffline = call.argument<Boolean>("offline") ?: true
                try {
                    start()
                    result.success(null)
                } catch (e: Exception) {
                    stop()
                    result.error("start_failed", e.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(type: String, text: String? = null, value: Double? = null) {
        main.post {
            events?.success(mapOf("type" to type, "text" to text, "value" to value))
        }
    }

    private fun start() {
        if (running) return
        running = true
        loudChunksWithoutResult = 0
        startAudio()
        chooseEngine { if (running) startSession() }
    }

    fun stop() {
        running = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        closePipe()
        audioThread?.join(500)
        audioThread = null
        audioRecord?.run {
            try {
                stop()
            } catch (_: IllegalStateException) {
            }
            release()
        }
        audioRecord = null
        emit("level", value = 0.0)
    }

    // --- Engine selection ---------------------------------------------------

    /** Picks offline recognition when a model for [locale] is installed. */
    private fun chooseEngine(then: () -> Unit) {
        engine = Engine.ONLINE
        if (!preferOffline || offlineFailed ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
        ) {
            announceEngine(downloading = false)
            then()
            return
        }

        val probe = recognitionIntent(null)
        querySupport("default", SpeechRecognizer.createSpeechRecognizer(context), probe) { default ->
            if (default?.installed == true) {
                engine = Engine.OFFLINE
                announceEngine(downloading = false)
                then()
                return@querySupport
            }
            if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                announceEngine(downloading = downloadModel(default, null, probe))
                then()
                return@querySupport
            }
            querySupport(
                "on-device",
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context),
                probe,
            ) { onDevice ->
                if (onDevice?.installed == true) {
                    engine = Engine.ON_DEVICE
                    announceEngine(downloading = false)
                } else {
                    announceEngine(downloading = downloadModel(default, onDevice, probe))
                }
                then()
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun querySupport(
        name: String,
        probe: SpeechRecognizer,
        intent: Intent,
        done: (Support?) -> Unit,
    ) {
        var answered = false
        fun finish(support: Support?) {
            if (answered) return
            answered = true
            probe.destroy()
            done(support)
        }
        main.postDelayed({
            if (!answered) Log.w(TAG, "$name support check timed out")
            finish(null)
        }, SUPPORT_CHECK_TIMEOUT_MS)

        probe.checkRecognitionSupport(intent, context.mainExecutor, object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                Log.i(
                    TAG,
                    "$name support for $locale: installed=${support.installedOnDeviceLanguages} " +
                        "pending=${support.pendingOnDeviceLanguages} " +
                        "supported=${support.supportedOnDeviceLanguages} " +
                        "online=${support.onlineLanguages}",
                )
                fun has(languages: List<String>) =
                    languages.any { it.replace('_', '-').equals(locale, ignoreCase = true) }
                finish(
                    Support(
                        installed = has(support.installedOnDeviceLanguages),
                        downloadable = has(support.supportedOnDeviceLanguages) &&
                            !has(support.pendingOnDeviceLanguages),
                    )
                )
            }

            override fun onError(error: Int) {
                Log.w(TAG, "$name support check failed: ${errorName(error)}")
                finish(null)
            }
        })
    }

    /** Asks a service able to install the model to download it; true if asked. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun downloadModel(default: Support?, onDevice: Support?, intent: Intent): Boolean {
        val service = when {
            onDevice?.downloadable == true -> SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            default?.downloadable == true -> SpeechRecognizer.createSpeechRecognizer(context)
            else -> return false
        }
        Log.i(TAG, "requesting download of the offline $locale model")
        service.triggerModelDownload(intent)
        // The request is handed over to the service; release our handle later.
        main.postDelayed({ service.destroy() }, 10_000)
        return true
    }

    private fun announceEngine(downloading: Boolean) {
        Log.i(TAG, "recognition engine: $engine${if (downloading) " (offline model downloading)" else ""}")
        emit("engine", text = if (downloading) "downloading" else engine.label)
    }

    private fun fallBackOnline(reason: String) {
        if (!running || engine == Engine.ONLINE) return
        Log.w(TAG, "offline recognition unusable ($reason), switching to online")
        offlineFailed = true
        engine = Engine.ONLINE
        loudChunksWithoutResult = 0
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        announceEngine(downloading = false)
        restartSession(100)
    }

    // --- Audio capture ------------------------------------------------------

    @Suppress("MissingPermission") // RECORD_AUDIO is requested by the Flutter side.
    private fun startAudio() {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            max(minBuffer, CHUNK_BYTES * 5),
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("AudioRecord could not be initialized")
        }
        record.startRecording()
        audioRecord = record

        audioThread = Thread({
            val buffer = ByteArray(CHUNK_BYTES)
            while (running) {
                val read = record.read(buffer, 0, buffer.size)
                if (read <= 0) continue
                val level = level(buffer, read)
                emit("level", value = level)
                if (engine != Engine.ONLINE && level > LOUD_LEVEL &&
                    ++loudChunksWithoutResult == LOUD_CHUNKS_BEFORE_FALLBACK
                ) {
                    main.post {
                        fallBackOnline("no result after ${LOUD_CHUNKS_BEFORE_FALLBACK / 10} s of speech")
                    }
                }
                val out = pipeOut ?: continue
                try {
                    out.write(buffer, 0, read)
                } catch (_: IOException) {
                    // The session ended and closed its end; the next session
                    // installs a fresh pipe.
                    if (pipeOut === out) pipeOut = null
                }
            }
        }, "VoiceFeedAudio").apply { start() }
    }

    /** RMS level of a PCM16 chunk mapped from -60..-10 dBFS to 0..1. */
    private fun level(buffer: ByteArray, length: Int): Double {
        var sum = 0.0
        var i = 0
        while (i + 1 < length) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort()
            sum += sample * sample.toDouble()
            i += 2
        }
        val rms = sqrt(sum / max(1, length / 2))
        val dbfs = 20 * log10(max(rms, 1.0) / 32768.0)
        return ((dbfs + 60) / 50).coerceIn(0.0, 1.0)
    }

    // --- Recognition sessions -----------------------------------------------

    private fun closePipe() {
        try {
            pipeOut?.close()
        } catch (_: IOException) {
        }
        pipeOut = null
        try {
            pipeIn?.close()
        } catch (_: IOException) {
        }
        pipeIn = null
    }

    private fun recognitionIntent(audio: ParcelFileDescriptor?) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            if (engine == Engine.OFFLINE) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            if (audio != null) {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audio)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
                // Keep one session alive for as long as the pipe delivers audio.
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            }
        }

    private fun createRecognizer(): SpeechRecognizer =
        if (engine == Engine.ON_DEVICE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }

    private fun startSession() {
        if (!running) return
        closePipe()
        val (readEnd, writeEnd) = ParcelFileDescriptor.createPipe()
        pipeIn = readEnd
        pipeOut = ParcelFileDescriptor.AutoCloseOutputStream(writeEnd)

        val speech = recognizer ?: createRecognizer().also {
            it.setRecognitionListener(this)
            recognizer = it
        }
        speech.startListening(recognitionIntent(readEnd))
        emit("status", text = "listening")
    }

    private fun restartSession(delayMs: Long) {
        main.postDelayed({ if (running) startSession() }, delayMs)
    }

    private fun firstResult(bundle: Bundle?): String? =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    override fun onPartialResults(partialResults: Bundle?) {
        firstResult(partialResults)?.let {
            loudChunksWithoutResult = 0
            emit("partial", text = it)
        }
    }

    override fun onSegmentResults(segmentResults: Bundle) {
        firstResult(segmentResults)?.let {
            loudChunksWithoutResult = 0
            emit("final", text = it)
        }
    }

    override fun onResults(results: Bundle?) {
        firstResult(results)?.let {
            loudChunksWithoutResult = 0
            emit("final", text = it)
        }
        restartSession(100)
    }

    override fun onEndOfSegmentedSession() {
        restartSession(100)
    }

    override fun onError(error: Int) {
        Log.w(TAG, "${errorName(error)} on $engine")
        if (engine != Engine.ONLINE && error in OFFLINE_FAILURES) {
            fallBackOnline(errorName(error))
            return
        }
        emit("error", text = errorName(error))
        if (error != SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            restartSession(
                when (error) {
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> 500
                    // Back off while the network is down instead of spinning.
                    SpeechRecognizer.ERROR_NETWORK,
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                    SpeechRecognizer.ERROR_SERVER,
                    SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> 1500
                    else -> 300
                }
            )
        }
    }

    private fun errorName(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "error_audio_error"
        SpeechRecognizer.ERROR_CLIENT -> "error_client"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_permission"
        SpeechRecognizer.ERROR_NETWORK -> "error_network"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "error_network_timeout"
        SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "error_busy"
        SpeechRecognizer.ERROR_SERVER -> "error_server"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "error_language_not_supported"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "error_language_unavailable"
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "error_server_disconnected"
        else -> "error_unknown ($error)"
    }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}
