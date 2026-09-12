import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/camera_provider.dart';

class PrompterCameraBackgroundPreview extends ConsumerWidget {
  const PrompterCameraBackgroundPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraState = ref.watch(cameraProvider);
    final controller = ref.watch(cameraProvider.notifier).controller;

    if (!cameraState.isEnabled ||
        !cameraState.isInitialized ||
        controller == null ||
        !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final isFrontCamera = cameraState.availableCameras.isNotEmpty &&
        cameraState.availableCameras[cameraState.selectedCameraIndex].lensDirection ==
            CameraLensDirection.front;

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final sensorWidth = controller.value.previewSize?.width ?? 1920;
    final sensorHeight = controller.value.previewSize?.height ?? 1080;
    final previewW = isLandscape ? sensorWidth : sensorHeight;
    final previewH = isLandscape ? sensorHeight : sensorWidth;

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: previewW.toDouble(),
                  height: previewH.toDouble(),
                  child: Transform.flip(
                    flipX: isFrontCamera, // Mirror selfie camera for natural view
                    child: CameraPreview(controller),
                  ),
                ),
              ),
            ),
          ),
          // Contrast scrim overlay to keep teleprompter text readable
          Container(
            color: Colors.black.withValues(alpha: cameraState.backgroundDim),
          ),
        ],
      ),
    );
  }
}

class PrompterCameraFloatingPreview extends ConsumerStatefulWidget {
  const PrompterCameraFloatingPreview({super.key});

  @override
  ConsumerState<PrompterCameraFloatingPreview> createState() =>
      _PrompterCameraFloatingPreviewState();
}

class _PrompterCameraFloatingPreviewState
    extends ConsumerState<PrompterCameraFloatingPreview> {
  Offset _offset = const Offset(24, 70);

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraProvider);
    final controller = ref.watch(cameraProvider.notifier).controller;

    if (!cameraState.isEnabled ||
        !cameraState.isInitialized ||
        controller == null ||
        !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final isFrontCamera = cameraState.availableCameras.isNotEmpty &&
        cameraState.availableCameras[cameraState.selectedCameraIndex].lensDirection ==
            CameraLensDirection.front;

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final width = isLandscape ? 220.0 : 135.0;
    final height = isLandscape ? 135.0 : 220.0;
    final sensorWidth = controller.value.previewSize?.width ?? 16;
    final sensorHeight = controller.value.previewSize?.height ?? 9;
    final previewW = isLandscape ? sensorWidth : sensorHeight;
    final previewH = isLandscape ? sensorHeight : sensorWidth;

    return Positioned(
      left: _offset.dx,
      top: _offset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _offset = Offset(
              (_offset.dx + details.delta.dx).clamp(8.0, size.width - width - 8.0),
              (_offset.dy + details.delta.dy).clamp(8.0, size.height - height - 8.0),
            );
          });
        },
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(16),
          color: Colors.black,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cameraState.isRecording ? Colors.redAccent : Colors.white24,
                width: cameraState.isRecording ? 2.5 : 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: previewW.toDouble(),
                      height: previewH.toDouble(),
                      child: Transform.flip(
                        flipX: isFrontCamera,
                        child: CameraPreview(controller),
                      ),
                    ),
                  ),
                  if (cameraState.isRecording)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'REC',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
