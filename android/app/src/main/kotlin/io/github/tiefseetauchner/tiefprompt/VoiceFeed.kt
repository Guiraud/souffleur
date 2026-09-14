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
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
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
 */
class VoiceFeed(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    RecognitionListener {

    companion object {
        const val METHOD_CHANNEL = "souffleur/voice_feed"
        const val EVENT_CHANNEL = "souffleur/voice_feed/events"
        private const val SAMPLE_RATE = 16000

        // 100 ms of 16-bit mono PCM.
        private const val CHUNK_BYTES = SAMPLE_RATE / 10 * 2
    }

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var locale = "fr-FR"

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
        startAudio()
        startSession()
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
                emit("level", value = level(buffer, read))
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

    private fun startSession() {
        if (!running) return
        closePipe()
        val (readEnd, writeEnd) = ParcelFileDescriptor.createPipe()
        pipeIn = readEnd
        pipeOut = ParcelFileDescriptor.AutoCloseOutputStream(writeEnd)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readEnd)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
            // Keep one session alive for as long as the pipe delivers audio.
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }

        val speech = recognizer ?: SpeechRecognizer.createSpeechRecognizer(context).also {
            it.setRecognitionListener(this)
            recognizer = it
        }
        speech.startListening(intent)
        emit("status", text = "listening")
    }

    private fun restartSession(delayMs: Long) {
        main.postDelayed({ if (running) startSession() }, delayMs)
    }

    private fun firstResult(bundle: Bundle?): String? =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    override fun onPartialResults(partialResults: Bundle?) {
        firstResult(partialResults)?.let { emit("partial", text = it) }
    }

    override fun onSegmentResults(segmentResults: Bundle) {
        firstResult(segmentResults)?.let { emit("final", text = it) }
    }

    override fun onResults(results: Bundle?) {
        firstResult(results)?.let { emit("final", text = it) }
        restartSession(100)
    }

    override fun onEndOfSegmentedSession() {
        restartSession(100)
    }

    override fun onError(error: Int) {
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
        else -> "error_unknown ($error)"
    }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}
