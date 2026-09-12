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
                      voiceState.currentWords.isNotEmpty
                          ? voiceState.currentWords
                          : context.tr('PrompterScreen.VoiceScroll_Listening'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontStyle: voiceState.currentWords.isNotEmpty
                            ? FontStyle.normal
                            : FontStyle.italic,
                        fontWeight: voiceState.isSpeaking
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (voiceState.isListening && voiceState.matchedWordIndex > 0)
                      Text(
                        voiceState.isSpeaking
                            ? 'Vitesse vocale : ~${voiceState.speechRateWpm.round()} mots/min'
                            : 'En pause (reprenez la parole pour faire défiler)',
                        style: TextStyle(
                          color: voiceState.isSpeaking
                              ? Colors.tealAccent
                              : Colors.white60,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
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
