import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/voice_scroll_provider.dart';

void main() {
  group('VoiceScrollProvider & Tokenization tests', () {
    test('Initial VoiceScrollState has expected default values', () {
      const state = VoiceScrollState();
      expect(state.isAvailable, isTrue);
      expect(state.isListening, isFalse);
      expect(state.scrollProgress, 0.0);
      expect(state.matchedWordIndex, 0);
      expect(state.totalWords, 0);
      expect(state.currentWords, isEmpty);
      expect(state.errorMessage, isNull);
    });

    test('VoiceScrollNotifier initializes correctly in ProviderContainer', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(voiceScrollProvider);
      expect(state.isListening, isFalse);
    });

    test('State copyWith updates fields properly', () {
      const state = VoiceScrollState();
      final updated = state.copyWith(
        isListening: true,
        scrollProgress: 0.45,
        matchedWordIndex: 12,
        currentWords: 'bonjour à tous',
      );

      expect(updated.isListening, isTrue);
      expect(updated.scrollProgress, 0.45);
      expect(updated.matchedWordIndex, 12);
      expect(updated.currentWords, 'bonjour à tous');
    });
  });
}
