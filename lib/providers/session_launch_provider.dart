import 'package:flutter_riverpod/flutter_riverpod.dart';

class LaunchWithCameraNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool val) => state = val;
  void toggle() => state = !state;
}

final launchWithCameraProvider =
    NotifierProvider<LaunchWithCameraNotifier, bool>(
  LaunchWithCameraNotifier.new,
);

class LaunchWithVoiceScrollNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool val) => state = val;
  void toggle() => state = !state;
}

final launchWithVoiceScrollProvider =
    NotifierProvider<LaunchWithVoiceScrollNotifier, bool>(
  LaunchWithVoiceScrollNotifier.new,
);
