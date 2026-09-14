import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/voice_scroll_provider.dart';

class VoiceScrollBanner extends ConsumerWidget {
  const VoiceScrollBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voiceState = ref.watch(voiceScrollProvider);
    if (!voiceState.isListening) return const SizedBox.shrink();

    // The recognized word is highlighted in the text itself; the banner only
    // reports status and the microphone level.
    final status = voiceState.isSpeaking
        ? 'Vitesse vocale : ~${voiceState.speechRateWpm.round()} mots/min'
        : (voiceState.matchedWordIndex > 0
              ? 'Reprenez votre lecture pour faire défiler'
              : (voiceState.infoMessage ??
                    context.tr('PrompterScreen.VoiceScroll_Listening')));

    return Positioned(
      bottom: 80,
      left: 20,
      right: 20,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.tealAccent, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                voiceState.isSpeaking ? Icons.graphic_eq : Icons.mic,
                color: voiceState.isSpeaking ? Colors.tealAccent : Colors.white70,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: TextStyle(
                        color: voiceState.isSpeaking
                            ? Colors.tealAccent
                            : Colors.white,
                        fontSize: 12,
                        fontStyle: voiceState.isSpeaking
                            ? FontStyle.normal
                            : FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    const _MicLevelMeter(),
                  ],
                ),
              ),
              if (voiceState.matchedWordIndex > 0) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () =>
                      ref.read(voiceScrollProvider.notifier).realignToLastMatch(),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.tealAccent.withValues(alpha: 0.6),
                        width: 1,
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.center_focus_strong,
                          color: Colors.tealAccent,
                          size: 13,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Recaler',
                          style: TextStyle(
                            color: Colors.tealAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () =>
                    ref.read(voiceScrollProvider.notifier).stopListening(),
                child: const Icon(Icons.close, color: Colors.white70, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live microphone level of the recognition session. A flat bar while
/// speaking means the recognizer gets no audio (e.g. the camera holds the mic).
class _MicLevelMeter extends ConsumerWidget {
  const _MicLevelMeter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(voiceSoundLevelProvider);
    return SizedBox(
      width: 140,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: level,
          minHeight: 5,
          backgroundColor: Colors.white12,
          color: level > 0.15 ? Colors.tealAccent : Colors.white38,
        ),
      ),
    );
  }
}
