import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum CameraPreviewMode {
  background, // Fullscreen behind prompter text
  floating,   // Movable Picture-in-Picture window
}

class CameraState {
  final bool isAvailable;
  final bool isInitialized;
  final bool isEnabled;
  final bool isRecording;
  final bool isPaused;
  final Duration recordingDuration;
  final CameraPreviewMode previewMode;
  final double backgroundDim; // 0.0 (transparent scrim) to 0.9 (dark scrim)
  final int selectedCameraIndex;
  final List<CameraDescription> availableCameras;
  final String? errorMessage;
  final String? infoMessage;
  final XFile? lastRecordedFile;
  final DeviceOrientation? lockedOrientation;
  final bool isAudioEnabled;

  const CameraState({
    this.isAvailable = true,
    this.isInitialized = false,
    this.isEnabled = false,
    this.isRecording = false,
    this.isPaused = false,
    this.recordingDuration = Duration.zero,
    this.previewMode = CameraPreviewMode.background,
    this.backgroundDim = 0.35,
    this.selectedCameraIndex = 0,
    this.availableCameras = const [],
    this.errorMessage,
    this.infoMessage,
    this.lastRecordedFile,
    this.lockedOrientation,
    this.isAudioEnabled = true,
  });

  CameraState copyWith({
    bool? isAvailable,
    bool? isInitialized,
    bool? isEnabled,
    bool? isRecording,
    bool? isPaused,
    Duration? recordingDuration,
    CameraPreviewMode? previewMode,
    double? backgroundDim,
    int? selectedCameraIndex,
    List<CameraDescription>? availableCameras,
    String? errorMessage,
    String? infoMessage,
    XFile? lastRecordedFile,
    DeviceOrientation? lockedOrientation,
    bool? isAudioEnabled,
    bool clearLockedOrientation = false,
    bool clearError = false,
    bool clearInfo = false,
    bool clearLastFile = false,
  }) {
    return CameraState(
      isAvailable: isAvailable ?? this.isAvailable,
      isInitialized: isInitialized ?? this.isInitialized,
      isEnabled: isEnabled ?? this.isEnabled,
      isRecording: isRecording ?? this.isRecording,
      isPaused: isPaused ?? this.isPaused,
      recordingDuration: recordingDuration ?? this.recordingDuration,
      previewMode: previewMode ?? this.previewMode,
      backgroundDim: backgroundDim ?? this.backgroundDim,
      selectedCameraIndex: selectedCameraIndex ?? this.selectedCameraIndex,
      availableCameras: availableCameras ?? this.availableCameras,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      infoMessage: clearInfo ? null : (infoMessage ?? this.infoMessage),
      lastRecordedFile: clearLastFile ? null : (lastRecordedFile ?? this.lastRecordedFile),
      lockedOrientation: clearLockedOrientation ? null : (lockedOrientation ?? this.lockedOrientation),
      isAudioEnabled: isAudioEnabled ?? this.isAudioEnabled,
    );
  }
}

class CameraNotifier extends Notifier<CameraState> {
  CameraController? _controller;
  Timer? _durationTimer;

  CameraController? get controller => _controller;

  @override
  CameraState build() {
    ref.onDispose(() {
      _durationTimer?.cancel();
      _controller?.dispose();
    });
    return const CameraState();
  }

  Future<void> enableCamera() async {
    if (state.isEnabled && state.isInitialized) return;

    try {
      List<CameraDescription> cameras = state.availableCameras;
      if (cameras.isEmpty) {
        cameras = await availableCameras();
      }

      if (cameras.isEmpty) {
        state = state.copyWith(
          isAvailable: false,
          isEnabled: false,
          errorMessage: 'No camera found on this device.',
        );
        return;
      }

      // Default to front-facing camera for teleprompter selfie view
      int defaultIndex = cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (defaultIndex == -1) defaultIndex = 0;

      await _initializeController(cameras, defaultIndex);
    } on UnimplementedError {
      state = state.copyWith(
        isAvailable: false,
        isEnabled: false,
        errorMessage: "Camera is not supported on this platform.",
      );
    } catch (e) {
      state = state.copyWith(
        isAvailable: false,
        isEnabled: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> _initializeController(
    List<CameraDescription> cameras,
    int cameraIndex, {
    bool enableAudio = true,
  }) async {
    await _controller?.dispose();
    _controller = null;

    final camera = cameras[cameraIndex];
    CameraController newController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: enableAudio,
    );

    try {
      await newController.initialize();
      _controller = newController;
      state = state.copyWith(
        isAvailable: true,
        isInitialized: true,
        isEnabled: true,
        isAudioEnabled: enableAudio,
        availableCameras: cameras,
        selectedCameraIndex: cameraIndex,
        clearError: true,
        infoMessage: enableAudio
            ? "Caméra et microphone activés pour l'enregistrement."
            : null,
      );
    } catch (e) {
      if (enableAudio) {
        // If audio permission or initialization failed, retry without audio
        try {
          await newController.dispose();
          newController = CameraController(
            camera,
            ResolutionPreset.high,
            enableAudio: false,
          );
          await newController.initialize();
          _controller = newController;
          state = state.copyWith(
            isAvailable: true,
            isInitialized: true,
            isEnabled: true,
            isAudioEnabled: false,
            availableCameras: cameras,
            selectedCameraIndex: cameraIndex,
            errorMessage:
                "Attention : Le microphone n'est pas activé. La vidéo sera enregistrée sans le son.",
          );
        } catch (retryError) {
          await newController.dispose();
          state = state.copyWith(
            isInitialized: false,
            isEnabled: false,
            isAudioEnabled: false,
            errorMessage: retryError.toString(),
          );
        }
      } else {
        await newController.dispose();
        state = state.copyWith(
          isInitialized: false,
          isEnabled: false,
          isAudioEnabled: false,
          errorMessage: e.toString(),
        );
      }
    }
  }

  Future<void> switchCamera() async {
    if (state.availableCameras.length <= 1) return;
    if (state.isRecording) return; // Switching while recording is not advised

    final nextIndex =
        (state.selectedCameraIndex + 1) % state.availableCameras.length;
    await _initializeController(
      state.availableCameras,
      nextIndex,
      enableAudio: state.isAudioEnabled,
    );
  }

  Future<void> toggleAudio() async {
    if (state.availableCameras.isEmpty || state.isRecording) return;
    final nextAudio = !state.isAudioEnabled;
    await _initializeController(
      state.availableCameras,
      state.selectedCameraIndex,
      enableAudio: nextAudio,
    );
  }

  Future<void> disableCamera() async {
    if (state.isRecording) {
      await stopRecording();
    }
    _durationTimer?.cancel();
    _durationTimer = null;
    await _controller?.dispose();
    _controller = null;
    state = state.copyWith(
      isEnabled: false,
      isInitialized: false,
      isRecording: false,
      recordingDuration: Duration.zero,
    );
  }

  void toggleCamera() {
    if (state.isEnabled) {
      disableCamera();
    } else {
      enableCamera();
    }
  }

  void setPreviewMode(CameraPreviewMode mode) {
    state = state.copyWith(previewMode: mode);
  }

  void setBackgroundDim(double dim) {
    state = state.copyWith(backgroundDim: dim.clamp(0.0, 0.9));
  }

  Future<void> startRecording() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state.isRecording) return;

    try {
      await c.startVideoRecording();
      _durationTimer?.cancel();
      state = state.copyWith(
        isRecording: true,
        isPaused: false,
        recordingDuration: Duration.zero,
        clearError: true,
      );
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        state = state.copyWith(
          recordingDuration: state.recordingDuration + const Duration(seconds: 1),
        );
      });
    } catch (e) {
      state = state.copyWith(errorMessage: 'Recording failed: $e');
    }
  }

  Future<XFile?> stopRecording() async {
    final c = _controller;
    if (c == null || !state.isRecording) return null;

    _durationTimer?.cancel();
    _durationTimer = null;

    try {
      final file = await c.stopVideoRecording();
      state = state.copyWith(
        isRecording: false,
        isPaused: false,
        lastRecordedFile: file,
      );
      return file;
    } catch (e) {
      state = state.copyWith(
        isRecording: false,
        isPaused: false,
        errorMessage: 'Failed to stop recording: $e',
      );
      return null;
    }
  }

  Future<void> pauseRecording() async {
    final c = _controller;
    if (c == null || !state.isRecording || state.isPaused) return;
    try {
      await c.pauseVideoRecording();
      _durationTimer?.cancel();
      state = state.copyWith(isPaused: true);
    } catch (e) {
      state = state.copyWith(errorMessage: 'Pause failed: $e');
    }
  }

  Future<void> resumeRecording() async {
    final c = _controller;
    if (c == null || !state.isRecording || !state.isPaused) return;
    try {
      await c.resumeVideoRecording();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        state = state.copyWith(
          recordingDuration: state.recordingDuration + const Duration(seconds: 1),
        );
      });
      state = state.copyWith(isPaused: false);
    } catch (e) {
      state = state.copyWith(errorMessage: 'Resume failed: $e');
    }
  }

  Future<void> toggleOrientation() async {
    if (state.lockedOrientation == DeviceOrientation.portraitUp) {
      await setOrientation(DeviceOrientation.landscapeLeft);
    } else {
      await setOrientation(DeviceOrientation.portraitUp);
    }
  }

  Future<void> setOrientation(DeviceOrientation? orientation) async {
    state = state.copyWith(
      lockedOrientation: orientation,
      clearLockedOrientation: orientation == null,
    );
    if (orientation == DeviceOrientation.portraitUp) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else if (orientation == DeviceOrientation.landscapeLeft) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    try {
      if (orientation != null) {
        await _controller?.lockCaptureOrientation(orientation);
      } else {
        await _controller?.unlockCaptureOrientation();
      }
    } catch (_) {}
  }

  void clearLastRecordedFile() {
    state = state.copyWith(clearLastFile: true);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void clearInfo() {
    state = state.copyWith(clearInfo: true);
  }
}

final cameraProvider = NotifierProvider<CameraNotifier, CameraState>(
  CameraNotifier.new,
);
