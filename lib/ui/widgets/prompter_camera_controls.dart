import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/camera_provider.dart';
import 'package:tiefprompt/ui/widgets/recorded_video_dialog.dart';

class PrompterCameraControlsOverlay extends ConsumerWidget {
  const PrompterCameraControlsOverlay({super.key});

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraState = ref.watch(cameraProvider);
    if (!cameraState.isEnabled) return const SizedBox.shrink();

    return Stack(
      children: [
        // Live recording status badge
        if (cameraState.isRecording)
          Positioned(
            top: 16,
            left: 16,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.redAccent, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulsingRedDot(),
                    const SizedBox(width: 8),
                    Text(
                      'REC ${_formatDuration(cameraState.recordingDuration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Camera control pill toolbar
        Positioned(
          top: 16,
          right: 16,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white24, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Record / Stop Button
                  IconButton(
                    icon: Icon(
                      cameraState.isRecording
                          ? Icons.stop_circle
                          : Icons.radio_button_checked,
                      color: Colors.redAccent,
                      size: 28,
                    ),
                    tooltip: cameraState.isRecording
                        ? context.tr('PrompterScreen.Camera_Stop')
                        : context.tr('PrompterScreen.Camera_Record'),
                    onPressed: () async {
                      if (cameraState.isRecording) {
                        final duration = cameraState.recordingDuration;
                        final file = await ref
                            .read(cameraProvider.notifier)
                            .stopRecording();
                        if (file != null && context.mounted) {
                          showDialog(
                            context: context,
                            builder: (ctx) => RecordedVideoDialog(
                              videoFile: file,
                              duration: duration,
                            ),
                          );
                        }
                      } else {
                        await ref
                            .read(cameraProvider.notifier)
                            .startRecording();
                      }
                    },
                  ),

                  // Switch front/back camera
                  if (cameraState.availableCameras.length > 1 &&
                      !cameraState.isRecording)
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios,
                          color: Colors.white, size: 22),
                      tooltip: context.tr('PrompterScreen.Camera_Switch'),
                      onPressed: () =>
                          ref.read(cameraProvider.notifier).switchCamera(),
                    ),

                  // Toggle mode (Fullscreen background vs Floating PiP)
                  IconButton(
                    icon: Icon(
                      cameraState.previewMode == CameraPreviewMode.background
                          ? Icons.picture_in_picture_alt
                          : Icons.fullscreen,
                      color: Colors.white,
                      size: 22,
                    ),
                    tooltip: cameraState.previewMode ==
                            CameraPreviewMode.background
                        ? context.tr('PrompterScreen.Camera_Mode_Floating')
                        : context.tr('PrompterScreen.Camera_Mode_Background'),
                    onPressed: () {
                      final newMode = cameraState.previewMode ==
                              CameraPreviewMode.background
                          ? CameraPreviewMode.floating
                          : CameraPreviewMode.background;
                      ref.read(cameraProvider.notifier).setPreviewMode(newMode);
                    },
                  ),

                  // Toggle Portrait / Landscape
                  IconButton(
                    icon: Icon(
                      MediaQuery.of(context).orientation == Orientation.portrait
                          ? Icons.stay_current_portrait
                          : Icons.stay_current_landscape,
                      color: Colors.white,
                      size: 22,
                    ),
                    tooltip: context.tr('PrompterScreen.Camera_Orientation'),
                    onPressed: () =>
                        ref.read(cameraProvider.notifier).toggleOrientation(),
                  ),

                  // Background dim slider (only in background mode)
                  if (cameraState.previewMode == CameraPreviewMode.background)
                    IconButton(
                      icon: const Icon(Icons.tune, color: Colors.white, size: 22),
                      tooltip: context.tr('PrompterScreen.Camera_Dimmer'),
                      onPressed: () => _showDimmerSheet(context, ref),
                    ),

                  // Close camera button
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                    tooltip: context.tr('PrompterScreen.Camera_Close'),
                    onPressed: () =>
                        ref.read(cameraProvider.notifier).disableCamera(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showDimmerSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Consumer(
          builder: (ctx, ref, _) {
            final dim = ref.watch(cameraProvider.select((s) => s.backgroundDim));
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24.0, vertical: 20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('PrompterScreen.Camera_Dimmer'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Slider(
                      value: dim,
                      min: 0.0,
                      max: 0.85,
                      divisions: 17,
                      label: '${(dim * 100).toInt()}%',
                      activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: (val) {
                        ref.read(cameraProvider.notifier).setBackgroundDim(val);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PulsingRedDot extends StatefulWidget {
  const _PulsingRedDot();

  @override
  State<_PulsingRedDot> createState() => _PulsingRedDotState();
}

class _PulsingRedDotState extends State<_PulsingRedDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
