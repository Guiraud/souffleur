import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:tiefprompt/services/voice_feed.dart';

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

/// French stop words that should not trigger single-word tracking jumps
const Set<String> _frenchStopWords = {
  'le', 'la', 'les', 'de', 'du', 'des', 'un', 'une',
  'et', 'en', 'ce', 'ces', 'au', 'aux', 'se', 'sa',
  'son', 'ses', 'si', 'on', 'ou', 'ne', 'pas', 'que',
  'qui', 'dans', 'sur', 'par', 'a', 'y',
};

/// Compares two normalized words with fuzzy tolerance (stem/prefix matching, edit distance).
bool wordsFuzzyEqual(String normA, String normB) {
  if (normA == normB) return true;
  if (normA.isEmpty || normB.isEmpty) return false;

  // Prefix matching if one word starts with the other with small length difference (e.g. plural: 'presentation' vs 'presentations')
  if (normA.length >= 4 &&
      normB.length >= 4 &&
      (normA.length - normB.length).abs() <= 2) {
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

/// Sliding search zone around the reader's position, in script words: a match
/// may end at most [_zoneBehind] words back and [_zoneAheadShort] (2-word
/// phrases) or [_zoneAheadLong] (3-4 words) ahead, so a word or phrase that
/// reappears further in the text can no longer pull the position there.
/// Leaving the zone goes through [findFarMatch].
const int _zoneBehind = 2;
const int _zoneAheadShort = 25;
const int _zoneAheadLong = 40;

/// A single word is only trusted among the next few expected words.
const int _singleWordAhead = 3;

bool _isContentWord(String word) =>
    word.length >= 3 && !_frenchStopWords.contains(word);

int? findMatchInScript({
  required List<ScriptToken> scriptTokens,
  required List<String> spokenNormWords,
  required int currentIndex,
}) {
  if (scriptTokens.isEmpty || spokenNormWords.isEmpty) return null;

  // 1. Last 4, 3 then 2 spoken words as a phrase, nearest occurrence in the zone.
  for (int seqLen = 4; seqLen >= 2; seqLen--) {
    if (spokenNormWords.length < seqLen) continue;
    final phrase = spokenNormWords.sublist(spokenNormWords.length - seqLen);
    // Two stop words ("de la", "et le") occur everywhere, even in the zone.
    if (seqLen == 2 && !phrase.any(_isContentWord)) continue;
    final match = _searchPhrase(
      scriptTokens,
      phrase,
      currentIndex,
      ahead: seqLen == 2 ? _zoneAheadShort : _zoneAheadLong,
    );
    if (match != null) return match;
  }

  // 2. Last spoken word alone, only if it is one of the next expected words.
  final word = spokenNormWords.last;
  if (_isContentWord(word)) {
    final first = currentIndex.clamp(0, scriptTokens.length - 1);
    final last = (currentIndex + _singleWordAhead).clamp(0, scriptTokens.length - 1);
    for (int i = first; i <= last; i++) {
      if (wordsFuzzyEqual(scriptTokens[i].normalized, word)) return i;
    }
  }

  return null;
}

/// Occurrence of the last 4 spoken words outside the sliding zone, for when
/// the reader skipped ahead or went back. Needs 2 content words so common
/// phrases cannot match; the caller should confirm it before jumping.
int? findFarMatch({
  required List<ScriptToken> scriptTokens,
  required List<String> spokenNormWords,
  required int currentIndex,
}) {
  const length = 4;
  if (spokenNormWords.length < length) return null;
  final phrase = spokenNormWords.sublist(spokenNormWords.length - length);
  if (phrase.where(_isContentWord).length < 2) return null;

  int? best;
  int bestDistance = 1 << 30;
  for (int end = length - 1; end < scriptTokens.length; end++) {
    final inZone = end >= currentIndex - _zoneBehind &&
        end <= currentIndex + _zoneAheadLong;
    if (inZone || !_phraseEndsAt(scriptTokens, phrase, end)) continue;
    // Prefer forward progression by weighting backward jumps more heavily.
    final distance = end >= currentIndex
        ? end - currentIndex
        : (currentIndex - end) * 2;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = end;
    }
  }
  return best;
}

/// Nearest occurrence of [phrase] whose last word lies in the sliding zone,
/// preferring forward progress over re-matching what was just read.
int? _searchPhrase(
  List<ScriptToken> script,
  List<String> phrase,
  int currentIndex, {
  required int ahead,
}) {
  final firstEnd = math.max(phrase.length - 1, currentIndex - _zoneBehind);
  final lastEnd = math.min(script.length - 1, currentIndex + ahead);

  int? best;
  int bestDistance = 1 << 30;
  for (int end = firstEnd; end <= lastEnd; end++) {
    if (!_phraseEndsAt(script, phrase, end)) continue;
    final distance = end >= currentIndex
        ? end - currentIndex
        : (currentIndex - end) * 3;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = end;
    }
  }
  return best;
}

bool _phraseEndsAt(List<ScriptToken> script, List<String> phrase, int end) {
  final start = end - phrase.length + 1;
  if (start < 0) return false;
  for (int j = 0; j < phrase.length; j++) {
    if (!wordsFuzzyEqual(script[start + j].normalized, phrase[j])) return false;
  }
  return true;
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
  final String? infoMessage;
  final int realignTrigger;
  // Character range in the script of the last matched word, -1 when none.
  final int highlightStart;
  final int highlightEnd;

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
    this.infoMessage,
    this.realignTrigger = 0,
    this.highlightStart = -1,
    this.highlightEnd = -1,
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
    String? infoMessage,
    int? realignTrigger,
    int? highlightStart,
    int? highlightEnd,
    bool clearError = false,
    bool clearInfo = false,
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
      infoMessage: clearInfo ? null : (infoMessage ?? this.infoMessage),
      realignTrigger: realignTrigger ?? this.realignTrigger,
      highlightStart: highlightStart ?? this.highlightStart,
      highlightEnd: highlightEnd ?? this.highlightEnd,
    );
  }
}

/// Picks the recognition locale: France French first (the Belgian, Swiss or
/// Canadian variants listed before it often have no installed model), then the
/// system locale when it is French, then any French variant.
String pickFrenchLocaleId(List<String> localeIds, {String? systemLocaleId}) {
  String norm(String id) => id.replaceAll('-', '_').toLowerCase();
  for (final id in localeIds) {
    if (norm(id) == 'fr_fr') return id;
  }
  if (systemLocaleId != null && norm(systemLocaleId).startsWith('fr')) {
    return systemLocaleId;
  }
  for (final id in localeIds) {
    if (norm(id).startsWith('fr')) return id;
  }
  return 'fr_FR';
}

/// Maps the recognizer's RMS level (Android: roughly -2..10 dB) to 0..1.
double normalizeSoundLevel(double rmsDb) =>
    ((rmsDb + 2) / 12).clamp(0.0, 1.0);

/// Microphone input level (0..1) of the running recognition session. Kept out
/// of [VoiceScrollState] so its frequent updates only rebuild the level meter.
class VoiceSoundLevelNotifier extends Notifier<double> {
  @override
  double build() => 0.0;

  void set(double level) => state = level;
}

final voiceSoundLevelProvider =
    NotifierProvider<VoiceSoundLevelNotifier, double>(
      VoiceSoundLevelNotifier.new,
    );

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
  int _consecutiveAudioErrors = 0;

  // Android 13+: recognition fed by the app's own mic capture (VoiceFeed),
  // which keeps working while the camera records sound.
  bool _usingFeed = false;
  StreamSubscription<VoiceFeedEvent>? _feedSub;

  // Far match waiting for a second recognition result to confirm it.
  int? _pendingJump;
  String? _pendingJumpWords;

  @override
  VoiceScrollState build() {
    ref.onDispose(() {
      _stopSpeech();
      _silenceTimer?.cancel();
      _restartTimer?.cancel();
    });
    return const VoiceScrollState();
  }

  void handleSpeechError(SpeechRecognitionError val) {
    final errorMsg = val.errorMsg.toLowerCase();
    // val.permanent is not used: the Android plugin flags every error as
    // permanent, including benign timeouts.

    // error_audio(_error): the recognizer could not capture the microphone
    // (e.g. held by the camera while recording). Keep retrying, but surface it
    // once when it persists instead of passing a dead mic off as silence.
    if (errorMsg.contains('error_audio')) {
      _consecutiveAudioErrors++;
      if (_consecutiveAudioErrors == 3) {
        state = state.copyWith(
          errorMessage:
              'Microphone indisponible pour le suivi vocal (utilisé par la caméra ?).',
          isSpeaking: false,
        );
      } else {
        state = state.copyWith(
          clearError: true,
          infoMessage: 'En attente du texte...',
          isSpeaking: false,
        );
      }
      _scheduleRestartListening(
        delayMs: _consecutiveAudioErrors >= 3 ? 1500 : 300,
      );
      return;
    }

    // Speech timeout, silence, or no match are normal waiting conditions in speech recognition
    final isTimeoutOrSilence = errorMsg.contains('timeout') ||
        errorMsg.contains('no_match') ||
        errorMsg.contains('speech_timeout') ||
        errorMsg.contains('pas de parole') ||
        errorMsg.contains('silence');

    final isBusy = errorMsg.contains('busy');

    if (isTimeoutOrSilence) {
      // Instead of an error, replace with an info message waiting for text/speech
      state = state.copyWith(
        clearError: true,
        infoMessage: 'En attente du texte...',
        isSpeaking: false,
      );
      // Seamlessly restart listening so voice tracking continues when user speaks again
      _scheduleRestartListening(delayMs: 300);
      return;
    }

    if (isBusy) {
      _scheduleRestartListening(delayMs: 400);
      return;
    }

    String displayError = val.errorMsg;
    if (errorMsg.contains('permission')) {
      displayError = 'Permission microphone requise pour le suivi vocal.';
    }

    state = state.copyWith(
      errorMessage: displayError,
      isSpeaking: false,
    );
  }

  void _scheduleRestartListening({int delayMs = 200}) {
    if (!state.isListening) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(Duration(milliseconds: delayMs), () {
      if (state.isListening) {
        _restartListening();
      }
    });
  }

  Future<void> _ensureInitialized() async {
    if (_speechInitialized) return;
    try {
      _speechInitialized = await _speechToText.initialize(
        onError: (val) {
          handleSpeechError(val);
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (state.isListening && _speechToText.isAvailable) {
              _scheduleRestartListening(delayMs: 200);
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
      final system = await _speechToText.systemLocale();
      return pickFrenchLocaleId(
        [for (final loc in locales) loc.localeId],
        systemLocaleId: system?.localeId,
      );
    } catch (_) {}
    return 'fr_FR';
  }

  /// Shared by the initial listen and every restart so both stay in sync.
  /// A long silence window and session keep the recognizer from cutting the
  /// session on every breath; the restart loop covers what is left.
  SpeechListenOptions get _listenOptions => SpeechListenOptions(
    listenMode: ListenMode.dictation,
    partialResults: true,
    cancelOnError: false,
    localeId: _selectedLocaleId,
    // Android caps the silence window at 10 s.
    pauseFor: const Duration(seconds: 10),
    listenFor: const Duration(minutes: 10),
  );

  void _restartListening() {
    // The native feed restarts its own sessions.
    if (!state.isListening || _usingFeed) return;
    try {
      // The plugin can still report a session that is winding down; retry
      // later instead of giving up, otherwise tracking silently dies.
      if (_speechToText.isListening) {
        _scheduleRestartListening(delayMs: 400);
        return;
      }
      _speechToText.listen(
        onResult: (result) {
          _onSpeechResult(result.recognizedWords);
        },
        onSoundLevelChange: _onSoundLevel,
        listenOptions: _listenOptions,
      );
    } catch (_) {
      _scheduleRestartListening(delayMs: 500);
    }
  }

  Future<void> startListening(String scriptText, {String? localeId}) async {
    _usingFeed = await VoiceFeed.isSupported();
    if (!_usingFeed) {
      await _ensureInitialized();
      if (!_speechInitialized) {
        state = state.copyWith(
          isListening: false,
          errorMessage: 'Reconnaissance vocale non disponible sur cet appareil.',
        );
        return;
      }
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

    _selectedLocaleId =
        localeId ?? (_usingFeed ? 'fr-FR' : await _resolveFrenchLocale());

    state = state.copyWith(
      isListening: true,
      isSpeaking: false,
      currentWords: '',
      scrollProgress: 0.0,
      matchedWordIndex: 0,
      totalWords: _scriptTokens.length,
      speechRateWpm: 140.0,
      clearError: true,
      infoMessage: 'En attente du texte...',
      highlightStart: -1,
      highlightEnd: -1,
    );

    _lastMatchTime = null;
    _currentWpm = 140.0;
    _consecutiveAudioErrors = 0;
    _pendingJump = null;
    _pendingJumpWords = null;

    try {
      if (_usingFeed) {
        await _feedSub?.cancel();
        _feedSub = VoiceFeed.events.listen(_onFeedEvent);
        await VoiceFeed.start(_selectedLocaleId);
      } else {
        await _speechToText.listen(
          onResult: (result) {
            _onSpeechResult(result.recognizedWords);
          },
          onSoundLevelChange: _onSoundLevel,
          listenOptions: _listenOptions,
        );
      }
    } catch (e) {
      state = state.copyWith(
        isListening: false,
        errorMessage: 'Impossible de démarrer l\'écoute: $e',
      );
    }
  }

  void _onFeedEvent(VoiceFeedEvent event) {
    switch (event.type) {
      case 'partial' || 'final':
        final text = event.text;
        if (text != null) _onSpeechResult(text);
      case 'level':
        ref.read(voiceSoundLevelProvider.notifier).set(event.value ?? 0.0);
      case 'error':
        handleSpeechError(
          SpeechRecognitionError(event.text ?? 'error_unknown', false),
        );
    }
  }

  void _onSoundLevel(double level) {
    ref.read(voiceSoundLevelProvider.notifier).set(normalizeSoundLevel(level));
  }

  void _onSpeechResult(String recognizedWords) {
    _consecutiveAudioErrors = 0;
    if (recognizedWords.isEmpty || _scriptTokens.isEmpty) return;

    final spokenWords = tokenizeSpoken(recognizedWords);
    if (spokenWords.isEmpty) return;

    var match = findMatchInScript(
      scriptTokens: _scriptTokens,
      spokenNormWords: spokenWords,
      currentIndex: state.matchedWordIndex,
    );
    if (match != null) {
      _pendingJump = null;
    } else {
      match = _confirmedFarMatch(spokenWords, recognizedWords);
    }

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
      _lastMatchTime = now;
    } else if (match != null) {
      _lastMatchTime = now;
    }

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
        highlightStart: charOffset,
        highlightEnd: charOffset + _scriptTokens[match].raw.length,
        clearInfo: true,
      );
    } else {
      state = state.copyWith(
        currentWords: recognizedWords,
        isSpeaking: true,
        clearInfo: true,
      );
    }
  }

  Future<void> _stopSpeech() async {
    _silenceTimer?.cancel();
    _restartTimer?.cancel();
    if (_usingFeed) {
      await _feedSub?.cancel();
      _feedSub = null;
      try {
        await VoiceFeed.stop();
      } catch (_) {}
      return;
    }
    try {
      await _speechToText.stop();
    } catch (_) {}
  }

  Future<void> stopListening() async {
    await _stopSpeech();
    state = state.copyWith(
      isListening: false,
      isSpeaking: false,
      highlightStart: -1,
      highlightEnd: -1,
    );
    ref.read(voiceSoundLevelProvider.notifier).set(0.0);
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

  /// A match outside the sliding zone is only followed once two different
  /// recognition results agree on it, so one mis-heard phrase cannot move the
  /// text to another paragraph.
  int? _confirmedFarMatch(List<String> spokenWords, String recognizedWords) {
    final far = findFarMatch(
      scriptTokens: _scriptTokens,
      spokenNormWords: spokenWords,
      currentIndex: state.matchedWordIndex,
    );
    final pending = _pendingJump;
    if (far != null &&
        pending != null &&
        far >= pending &&
        far - pending <= 4 &&
        recognizedWords != _pendingJumpWords) {
      _pendingJump = null;
      return far;
    }
    _pendingJump = far;
    _pendingJumpWords = far == null ? null : recognizedWords;
    return null;
  }

  @visibleForTesting
  void debugLoadScript(String scriptText) {
    _scriptTextLength = scriptText.length;
    _scriptTokens = tokenizeScript(scriptText);
    state = state.copyWith(isListening: true, totalWords: _scriptTokens.length);
  }

  @visibleForTesting
  void debugSpeechResult(String recognizedWords) =>
      _onSpeechResult(recognizedWords);

  void realignToLastMatch() {
    state = state.copyWith(realignTrigger: state.realignTrigger + 1);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void clearInfo() {
    state = state.copyWith(clearInfo: true);
  }
}

final voiceScrollProvider =
    NotifierProvider<VoiceScrollNotifier, VoiceScrollState>(
  VoiceScrollNotifier.new,
);
