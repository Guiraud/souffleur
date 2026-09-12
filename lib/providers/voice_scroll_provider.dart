import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceScrollState {
  final bool isAvailable;
  final bool isListening;
  final String currentWords;
  final double scrollProgress; // 0.0 to 1.0
  final int matchedWordIndex;
  final int totalWords;
  final String? errorMessage;

  const VoiceScrollState({
    this.isAvailable = true,
    this.isListening = false,
    this.currentWords = '',
    this.scrollProgress = 0.0,
    this.matchedWordIndex = 0,
    this.totalWords = 0,
    this.errorMessage,
  });

  VoiceScrollState copyWith({
    bool? isAvailable,
    bool? isListening,
    String? currentWords,
    double? scrollProgress,
    int? matchedWordIndex,
    int? totalWords,
    String? errorMessage,
    bool clearError = false,
  }) {
    return VoiceScrollState(
      isAvailable: isAvailable ?? this.isAvailable,
      isListening: isListening ?? this.isListening,
      currentWords: currentWords ?? this.currentWords,
      scrollProgress: scrollProgress ?? this.scrollProgress,
      matchedWordIndex: matchedWordIndex ?? this.matchedWordIndex,
      totalWords: totalWords ?? this.totalWords,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class VoiceScrollNotifier extends Notifier<VoiceScrollState> {
  final SpeechToText _speechToText = SpeechToText();
  List<String> _scriptWords = [];
  bool _speechInitialized = false;

  @override
  VoiceScrollState build() {
    ref.onDispose(() {
      _stopSpeech();
    });
    return const VoiceScrollState();
  }

  Future<void> _ensureInitialized() async {
    if (_speechInitialized) return;
    try {
      _speechInitialized = await _speechToText.initialize(
        onError: (val) {
          state = state.copyWith(errorMessage: val.errorMsg);
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            // Keep state or auto-restart if still flagged listening
            if (state.isListening && _speechToText.isAvailable) {
              _restartListening();
            }
          }
        },
      );
      state = state.copyWith(isAvailable: _speechInitialized);
    } catch (e) {
      _speechInitialized = false;
      state = state.copyWith(
        isAvailable: false,
        errorMessage: 'Voice recognition initialization failed: $e',
      );
    }
  }

  void _restartListening() {
    if (!state.isListening) return;
    try {
      _speechToText.listen(
        onResult: (result) {
          _onSpeechResult(result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
      );
    } catch (_) {}
  }

  Future<void> startListening(String scriptText, {String? localeId}) async {
    await _ensureInitialized();
    if (!_speechInitialized) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Speech recognition is not available on this device.',
      );
      return;
    }

    _scriptWords = _tokenize(scriptText);
    if (_scriptWords.isEmpty) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Script is empty.',
      );
      return;
    }

    state = state.copyWith(
      isListening: true,
      currentWords: '',
      scrollProgress: 0.0,
      matchedWordIndex: 0,
      totalWords: _scriptWords.length,
      clearError: true,
    );

    try {
      await _speechToText.listen(
        onResult: (result) {
          _onSpeechResult(result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          localeId: localeId,
        ),
      );
    } catch (e) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Failed to start listening: $e',
      );
    }
  }

  void _onSpeechResult(String recognizedWords) {
    if (recognizedWords.isEmpty || _scriptWords.isEmpty) return;

    final spokenWords = _tokenize(recognizedWords);
    if (spokenWords.isEmpty) return;

    final match = _findMatchInScript(
      scriptWords: _scriptWords,
      spokenWords: spokenWords,
      currentIndex: state.matchedWordIndex,
    );

    if (match != null && match >= state.matchedWordIndex) {
      final double progress = (match / (_scriptWords.length - 1)).clamp(0.0, 1.0);
      state = state.copyWith(
        currentWords: recognizedWords,
        matchedWordIndex: match,
        scrollProgress: progress,
      );
    } else {
      state = state.copyWith(currentWords: recognizedWords);
    }
  }

  int? _findMatchInScript({
    required List<String> scriptWords,
    required List<String> spokenWords,
    required int currentIndex,
  }) {
    // Attempt multi-word sequence match from the tail of spoken words (2-4 words)
    for (int seqLen = 4; seqLen >= 2; seqLen--) {
      if (spokenWords.length >= seqLen) {
        final phrase = spokenWords.sublist(spokenWords.length - seqLen);
        final match = _searchPhrase(scriptWords, phrase, currentIndex);
        if (match != null) return match;
      }
    }

    // Fallback: match the single last spoken word
    if (spokenWords.isNotEmpty) {
      final lastWord = spokenWords.last;
      return _searchSingleWord(scriptWords, lastWord, currentIndex);
    }

    return null;
  }

  int? _searchPhrase(List<String> script, List<String> phrase, int currentIndex) {
    final searchStart = (currentIndex - 2).clamp(0, script.length - 1);
    final searchEnd = (currentIndex + 40).clamp(0, script.length);

    for (int i = searchStart; i <= searchEnd - phrase.length; i++) {
      bool matched = true;
      for (int j = 0; j < phrase.length; j++) {
        if (!_wordsFuzzyEqual(script[i + j], phrase[j])) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i + phrase.length - 1;
      }
    }
    return null;
  }

  int? _searchSingleWord(List<String> script, String word, int currentIndex) {
    if (word.length < 3) return null; // Avoid false positives on short stop words
    final searchStart = (currentIndex - 1).clamp(0, script.length - 1);
    final searchEnd = (currentIndex + 35).clamp(0, script.length);

    for (int i = searchStart; i < searchEnd; i++) {
      if (_wordsFuzzyEqual(script[i], word)) {
        return i;
      }
    }
    return null;
  }

  bool _wordsFuzzyEqual(String a, String b) {
    if (a == b) return true;
    if (a.length >= 4 && b.length >= 4) {
      return a.startsWith(b) || b.startsWith(a);
    }
    return false;
  }

  List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r"[^\wÀ-ÿ\s']"), ' ')
        .split(RegExp(r'\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  Future<void> _stopSpeech() async {
    try {
      await _speechToText.stop();
    } catch (_) {}
  }

  Future<void> stopListening() async {
    await _stopSpeech();
    state = state.copyWith(isListening: false);
  }

  void toggleVoiceScroll(String scriptText, {String? localeId}) {
    if (state.isListening) {
      stopListening();
    } else {
      startListening(scriptText, localeId: localeId);
    }
  }

  void resetProgress() {
    state = state.copyWith(
      scrollProgress: 0.0,
      matchedWordIndex: 0,
      currentWords: '',
    );
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

final voiceScrollProvider =
    NotifierProvider<VoiceScrollNotifier, VoiceScrollState>(
  VoiceScrollNotifier.new,
);
