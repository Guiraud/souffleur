import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/camera_provider.dart';

void main() {
  group('CameraProvider tests', () {
    test('Initial CameraState has expected default values', () {
      const state = CameraState();
      expect(state.isAvailable, isTrue);
      expect(state.isInitialized, isFalse);
      expect(state.isEnabled, isFalse);
      expect(state.isRecording, isFalse);
      expect(state.previewMode, CameraPreviewMode.background);
      expect(state.backgroundDim, 0.35);
      expect(state.recordingDuration, Duration.zero);
      expect(state.errorMessage, isNull);
    });

    test('CameraNotifier toggles preview modes and background dim', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(cameraProvider.notifier);

      notifier.setPreviewMode(CameraPreviewMode.floating);
      expect(container.read(cameraProvider).previewMode, CameraPreviewMode.floating);

      notifier.setBackgroundDim(0.5);
      expect(container.read(cameraProvider).backgroundDim, 0.5);

      // Clamping test
      notifier.setBackgroundDim(1.5);
      expect(container.read(cameraProvider).backgroundDim, 0.9);

      notifier.setBackgroundDim(-0.2);
      expect(container.read(cameraProvider).backgroundDim, 0.0);
    });
  });
}
