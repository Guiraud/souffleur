import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One event from the native voice feed.
///
/// [type] is `partial` / `final` (recognized [text]), `level` (microphone
/// level 0..1 in [value]), `error` (error code in [text]) or `status`.
class VoiceFeedEvent {
  final String type;
  final String? text;
  final double? value;

  const VoiceFeedEvent(this.type, {this.text, this.value});

  factory VoiceFeedEvent.fromMap(Map<Object?, Object?> map) => VoiceFeedEvent(
    map['type'] as String? ?? 'unknown',
    text: map['text'] as String?,
    value: (map['value'] as num?)?.toDouble(),
  );
}

/// Android 13+ speech recognition fed with the app's own microphone capture
/// (see android/.../VoiceFeed.kt). The recognition service never opens the
/// microphone itself, so Android does not silence it while the camera records
/// sound — unlike speech_to_text.
class VoiceFeed {
  static const _methods = MethodChannel('souffleur/voice_feed');
  static const _events = EventChannel('souffleur/voice_feed/events');

  static Future<bool> isSupported() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Stream<VoiceFeedEvent> get events => _events
      .receiveBroadcastStream()
      .map((event) => VoiceFeedEvent.fromMap(event as Map<Object?, Object?>));

  static Future<void> start(String localeId) =>
      _methods.invokeMethod('start', {'locale': localeId.replaceAll('_', '-')});

  static Future<void> stop() => _methods.invokeMethod('stop');
}
