import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

class ScriptToken {
  final String raw;
  final String normalized;
  final int charOffset;
  final int index;

  const ScriptToken({
    required this.raw,
    required this.normalized,
    required this.charOffset,
    required this.index,
  });

  @override
  String toString() => 'ScriptToken($raw, norm: $normalized, offset: $charOffset, idx: $index)';
}

/// Strips standard French accents and diacritics for insensitive matching.
String stripFrenchDiacritics(String text) {
  var result = text.toLowerCase()
      .replaceAll('œ', 'oe')
      .replaceAll('æ', 'ae');
  const withDia = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ';
  const withoutDia = 'aaaaaaceeeeiiiinooooouuuuyy';
  for (int i = 0; i < withDia.length; i++) {
    result = result.replaceAll(withDia[i], withoutDia[i]);
  }
  return result;
}

/// Normalizes a French word by removing diacritics and non-alphanumerics.
String normalizeFrenchWord(String word) {
  final stripped = stripFrenchDiacritics(word);
  return stripped.replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Splits script text into tokens while tracking exact character offsets in the original text.
List<ScriptToken> tokenizeScript(String text) {
  final tokens = <ScriptToken>[];
  final regExp = RegExp(r"[a-zA-ZÀ-ÿ0-9]+");
  final matches = regExp.allMatches(text);
  int index = 0;
  for (final m in matches) {
    final raw = m.group(0)!;
    final norm = normalizeFrenchWord(raw);
    if (norm.isNotEmpty) {
      tokens.add(ScriptToken(
        raw: raw,
        normalized: norm,
        charOffset: m.start,
        index: index++,
      ));
    }
  }
  return tokens;
}

/// Splits recognized spoken text into normalized words.
List<String> tokenizeSpoken(String text) {
  final regExp = RegExp(r"[a-zA-ZÀ-ÿ0-9]+");
  final matches = regExp.allMatches(text);
  final words = <String>[];
  for (final m in matches) {
    final norm = normalizeFrenchWord(m.group(0)!);
    if (norm.isNotEmpty) {
      words.add(norm);
    }
  }
  return words;
}

/// Compares two normalized words with fuzzy tolerance (stem/prefix matching, edit distance).
bool wordsFuzzyEqual(String normA, String normB) {
  if (normA == normB) return true;
  if (normA.isEmpty || normB.isEmpty) return false;

  // Prefix matching if one word starts with the other (e.g. plural: 'presentation' vs 'presentations')
  if (normA.length >= 4 && normB.length >= 4) {
    if (normA.startsWith(normB) || normB.startsWith(normA)) {
      return true;
    }
  }

  // Common stem matching for conjugations (e.g. 'decouvrir' vs 'decouvrez', stem: 'decouvr')
  int commonPrefixLen = 0;
  while (commonPrefixLen < normA.length &&
      commonPrefixLen < normB.length &&
      normA[commonPrefixLen] == normB[commonPrefixLen]) {
    commonPrefixLen++;
  }
  if (commonPrefixLen >= 5 &&
      (normA.length - commonPrefixLen) <= 3 &&
      (normB.length - commonPrefixLen) <= 3) {
    return true;
  }

  // Single typo tolerance for longer words (length >= 5)
  if (normA.length >= 5 && normB.length >= 5) {
    if ((normA.length - normB.length).abs() <= 1) {
      if (_editDistanceAtMostOne(normA, normB)) {
        return true;
      }
    }
  }

  return false;
}

bool _editDistanceAtMostOne(String s1, String s2) {
  if (s1 == s2) return true;
  if ((s1.length - s2.length).abs() > 1) return false;
  int i = 0, j = 0, diffs = 0;
  while (i < s1.length && j < s2.length) {
    if (s1[i] != s2[j]) {
      diffs++;
      if (diffs > 1) return false;
      if (s1.length > s2.length) {
        i++;
      } else if (s2.length > s1.length) {
        j++;
      } else {
        i++;
        j++;
      }
    } else {
      i++;
      j++;
    }
  }
  return true;
}

int? findMatchInScript({
  required List<ScriptToken> scriptTokens,
  required List<String> spokenNormWords,
  required int currentIndex,
}) {
  if (scriptTokens.isEmpty || spokenNormWords.isEmpty) return null;

  // 1. Multi-word phrase search (4, 3, 2 words) from tail of spoken words
  for (int seqLen = 4; seqLen >= 2; seqLen--) {
    if (spokenNormWords.length >= seqLen) {
      final phrase = spokenNormWords.sublist(spokenNormWords.length - seqLen);
      final match = _searchPhrase(scriptTokens, phrase, currentIndex);
      if (match != null) return match;
    }
  }

  // 2. Single-word search from tail (check last 2 spoken words, min length 2)
  for (int i = spokenNormWords.length - 1;
      i >= 0 && i >= spokenNormWords.length - 2;
      i--) {
    final word = spokenNormWords[i];
    if (word.length >= 2) {
      final match = _searchSingleWord(scriptTokens, word, currentIndex);
      if (match != null) return match;
    }
  }

  // 3. Global phrase search if speaker jumped ahead or restarted (3-word phrase)
  if (spokenNormWords.length >= 3) {
    final phrase = spokenNormWords.sublist(spokenNormWords.length - 3);
    final globalMatch = _searchGlobalPhrase(scriptTokens, phrase);
    if (globalMatch != null) return globalMatch;
  }

  return null;
}

int? _searchPhrase(
  List<ScriptToken> script,
  List<String> phrase,
  int currentIndex,
) {
  final searchStart = (currentIndex - 3).clamp(0, script.length - 1);
  final searchEnd = (currentIndex + 80).clamp(0, script.length);

  for (int i = searchStart; i <= searchEnd - phrase.length; i++) {
    bool matched = true;
    for (int j = 0; j < phrase.length; j++) {
      if (!wordsFuzzyEqual(script[i + j].normalized, phrase[j])) {
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

int? _searchSingleWord(
  List<ScriptToken> script,
  String word,
  int currentIndex,
) {
  final searchStart = (currentIndex - 1).clamp(0, script.length - 1);
  final searchEnd = (currentIndex + 45).clamp(0, script.length);

  for (int i = searchStart; i < searchEnd; i++) {
    if (wordsFuzzyEqual(script[i].normalized, word)) {
      return i;
    }
  }
  return null;
}

int? _searchGlobalPhrase(List<ScriptToken> script, List<String> phrase) {
  for (int i = 0; i <= script.length - phrase.length; i++) {
    bool matched = true;
    for (int j = 0; j < phrase.length; j++) {
      if (!wordsFuzzyEqual(script[i + j].normalized, phrase[j])) {
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

class VoiceScrollState {
  final bool isAvailable;
  final bool isListening;
  final String currentWords;
  final double scrollProgress; // 0.0 to 1.0 based on character position
  final int matchedWordIndex;
  final int totalWords;
  final bool isSpeaking; // true when words are actively detected (<1.5s ago)
  final double speechRateWpm; // detected words per minute
  final String? errorMessage;

  const VoiceScrollState({
    this.isAvailable = true,
    this.isListening = false,
    this.currentWords = '',
    this.scrollProgress = 0.0,
    this.matchedWordIndex = 0,
    this.totalWords = 0,
    this.isSpeaking = false,
    this.speechRateWpm = 140.0,
    this.errorMessage,
  });

  VoiceScrollState copyWith({
    bool? isAvailable,
    bool? isListening,
    String? currentWords,
    double? scrollProgress,
    int? matchedWordIndex,
    int? totalWords,
    bool? isSpeaking,
    double? speechRateWpm,
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
      isSpeaking: isSpeaking ?? this.isSpeaking,
      speechRateWpm: speechRateWpm ?? this.speechRateWpm,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class VoiceScrollNotifier extends Notifier<VoiceScrollState> {
  final SpeechToText _speechToText = SpeechToText();
  List<ScriptToken> _scriptTokens = [];
  int _scriptTextLength = 0;
  bool _speechInitialized = false;
  String _selectedLocaleId = 'fr_FR';

  Timer? _silenceTimer;
  Timer? _restartTimer;
  DateTime? _lastMatchTime;
  double _currentWpm = 140.0;

  @override
  VoiceScrollState build() {
    ref.onDispose(() {
      _stopSpeech();
      _silenceTimer?.cancel();
      _restartTimer?.cancel();
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
            if (state.isListening && _speechToText.isAvailable) {
              _restartTimer?.cancel();
              _restartTimer = Timer(const Duration(milliseconds: 150), () {
                if (state.isListening) {
                  _restartListening();
                }
              });
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

  Future<String> _resolveFrenchLocale() async {
    try {
      final locales = await _speechToText.locales();
      for (final loc in locales) {
        if (loc.localeId.toLowerCase().startsWith('fr')) {
          return loc.localeId;
        }
      }
    } catch (_) {}
    return 'fr_FR';
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
          localeId: _selectedLocaleId,
        ),
      );
    } catch (_) {}
  }

  Future<void> startListening(String scriptText, {String? localeId}) async {
    await _ensureInitialized();
    if (!_speechInitialized) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Reconnaissance vocale non disponible sur cet appareil.',
      );
      return;
    }

    _scriptTextLength = scriptText.length;
    _scriptTokens = tokenizeScript(scriptText);
    if (_scriptTokens.isEmpty) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Le texte du prompteur est vide.',
      );
      return;
    }

    _selectedLocaleId = localeId ?? await _resolveFrenchLocale();

    state = state.copyWith(
      isListening: true,
      isSpeaking: false,
      currentWords: '',
      scrollProgress: 0.0,
      matchedWordIndex: 0,
      totalWords: _scriptTokens.length,
      speechRateWpm: 140.0,
      clearError: true,
    );

    _lastMatchTime = null;
    _currentWpm = 140.0;

    try {
      await _speechToText.listen(
        onResult: (result) {
          _onSpeechResult(result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          localeId: _selectedLocaleId,
        ),
      );
    } catch (e) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Impossible de démarrer l\'écoute: $e',
      );
    }
  }

  void _onSpeechResult(String recognizedWords) {
    if (recognizedWords.isEmpty || _scriptTokens.isEmpty) return;

    final spokenWords = tokenizeSpoken(recognizedWords);
    if (spokenWords.isEmpty) return;

    final match = findMatchInScript(
      scriptTokens: _scriptTokens,
      spokenNormWords: spokenWords,
      currentIndex: state.matchedWordIndex,
    );

    final now = DateTime.now();

    // Calculate speaking pace (WPM)
    if (_lastMatchTime != null && match != null && match > state.matchedWordIndex) {
      final wordsDelta = match - state.matchedWordIndex;
      final timeDeltaSec = now.difference(_lastMatchTime!).inMilliseconds / 1000.0;
      if (timeDeltaSec >= 0.3 && timeDeltaSec <= 5.0) {
        final instantWpm = (wordsDelta / timeDeltaSec) * 60.0;
        if (instantWpm >= 50 && instantWpm <= 350) {
          _currentWpm = _currentWpm * 0.7 + instantWpm * 0.3;
        }
      }
    }
    _lastMatchTime = now;

    // Reset silence timer: user is speaking, will revert to silent after 1.5s of inactivity
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(milliseconds: 1500), () {
      state = state.copyWith(isSpeaking: false);
    });

    if (match != null) {
      final charOffset = _scriptTokens[match].charOffset;
      final textLen = _scriptTextLength > 0 ? _scriptTextLength : 1;
      final double progress = (charOffset / textLen).clamp(0.0, 1.0);

      state = state.copyWith(
        currentWords: recognizedWords,
        matchedWordIndex: match,
        scrollProgress: progress,
        isSpeaking: true,
        speechRateWpm: _currentWpm,
      );
    } else {
      state = state.copyWith(
        currentWords: recognizedWords,
        isSpeaking: true,
      );
    }
  }

  Future<void> _stopSpeech() async {
    _silenceTimer?.cancel();
    _restartTimer?.cancel();
    try {
      await _speechToText.stop();
    } catch (_) {}
  }

  Future<void> stopListening() async {
    await _stopSpeech();
    state = state.copyWith(
      isListening: false,
      isSpeaking: false,
    );
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
      isSpeaking: false,
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
