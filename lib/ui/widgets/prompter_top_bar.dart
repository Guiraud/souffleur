import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/camera_provider.dart';
import 'package:tiefprompt/providers/script_provider.dart';
import 'package:tiefprompt/providers/voice_scroll_provider.dart';

class PrompterTopBar extends ConsumerWidget {
  const PrompterTopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final script = ref.watch(scriptProvider);
    final cameraState = ref.watch(cameraProvider);
    final voiceScrollState = ref.watch(voiceScrollProvider);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 12.0),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.close,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  script.title ?? context.tr("empty_title"),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              // Camera toggle button in TopBar
              IconButton.filledTonal(
                style: IconButton.styleFrom(
                  backgroundColor: cameraState.isEnabled
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white24,
                  foregroundColor: cameraState.isEnabled
                      ? Theme.of(context).colorScheme.onPrimary
                      : Colors.white,
                ),
                icon: Icon(
                  cameraState.isEnabled ? Icons.videocam : Icons.videocam_outlined,
                  size: 22,
                ),
                tooltip: cameraState.isEnabled
                    ? context.tr("PrompterScreen.Camera_Close")
                    : context.tr("PrompterScreen.IconButton_Camera"),
                onPressed: () => ref.read(cameraProvider.notifier).toggleCamera(),
              ),
              const SizedBox(width: 8),
              // Voice Scroll toggle button in TopBar
              IconButton.filledTonal(
                style: IconButton.styleFrom(
                  backgroundColor: voiceScrollState.isListening
                      ? Colors.tealAccent.shade700
                      : Colors.white24,
                  foregroundColor: voiceScrollState.isListening
                      ? Colors.white
                      : Colors.white70,
                ),
                icon: Icon(
                  voiceScrollState.isListening ? Icons.mic : Icons.mic_none,
                  size: 22,
                ),
                tooltip: context.tr("PrompterScreen.IconButton_VoiceScroll"),
                onPressed: () {
                  ref.read(voiceScrollProvider.notifier).toggleVoiceScroll(script.text);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
