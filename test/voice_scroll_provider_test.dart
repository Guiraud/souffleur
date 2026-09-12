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
      expect(state.isSpeaking, isFalse);
      expect(state.speechRateWpm, 140.0);
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
        isSpeaking: true,
        speechRateWpm: 165.0,
      );

      expect(updated.isListening, isTrue);
      expect(updated.scrollProgress, 0.45);
      expect(updated.matchedWordIndex, 12);
      expect(updated.currentWords, 'bonjour à tous');
      expect(updated.isSpeaking, isTrue);
      expect(updated.speechRateWpm, 165.0);
    });

    test('stripFrenchDiacritics removes standard French accents', () {
      expect(stripFrenchDiacritics('àáâäçèéêëìíîïñòóôöùúûü'),
          'aaaaceeeeiiiinoooouuuu');
      expect(stripFrenchDiacritics('Cœur et œuvre'), 'coeur et oeuvre');
      expect(stripFrenchDiacritics('ÉVÉNEMENT'), 'evenement');
    });

    test('normalizeFrenchWord handles diacritics, casing and punctuation', () {
      expect(normalizeFrenchWord('Présentation'), 'presentation');
      expect(normalizeFrenchWord("l'application"), 'lapplication');
      expect(normalizeFrenchWord('très-bien!'), 'tresbien');
      expect(normalizeFrenchWord('aujourd’hui'), 'aujourdhui');
    });

    test('tokenizeScript preserves character offsets and creates tokens', () {
      const script = "Bonjour à tous, bienvenue dans l'application Souffleur !";
      final tokens = tokenizeScript(script);

      expect(tokens.isNotEmpty, isTrue);
      expect(tokens.first.raw, 'Bonjour');
      expect(tokens.first.normalized, 'bonjour');
      expect(tokens.first.charOffset, 0);

      final appToken = tokens.firstWhere((t) => t.raw == 'application');
      expect(appToken.normalized, 'application');
      expect(appToken.charOffset, script.indexOf('application'));
    });

    test('wordsFuzzyEqual matches exact, accents, prefix and close typos', () {
      expect(wordsFuzzyEqual('bonjour', 'bonjour'), isTrue);
      expect(wordsFuzzyEqual('presentation', 'presentations'), isTrue);
      expect(wordsFuzzyEqual('decouvrez', 'decouvrir'), isTrue);
      expect(wordsFuzzyEqual('souffleur', 'soufleur'), isTrue);
      expect(wordsFuzzyEqual('chat', 'chien'), isFalse);
    });

    test('findMatchInScript correctly matches phrases in sequence', () {
      const script =
          "Bonjour à tous et bienvenue dans cette nouvelle vidéo de démonstration de Souffleur.";
      final tokens = tokenizeScript(script);

      // Match first phrase
      final spoken1 = tokenizeSpoken("Bonjour à tous et bienvenue");
      final match1 = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: spoken1,
        currentIndex: 0,
      );
      expect(match1, isNotNull);
      expect(tokens[match1!].normalized, 'bienvenue');

      // Match subsequent phrase advancing forward
      final spoken2 = tokenizeSpoken("dans cette nouvelle vidéo");
      final match2 = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: spoken2,
        currentIndex: match1,
      );
      expect(match2, isNotNull);
      expect(match2! > match1, isTrue);
      expect(tokens[match2].normalized, 'video');

      // Match end of script
      final spoken3 = tokenizeSpoken("démonstration de Souffleur");
      final match3 = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: spoken3,
        currentIndex: match2,
      );
      expect(match3, isNotNull);
      expect(match3! > match2, isTrue);
      expect(tokens[match3].normalized, 'souffleur');
    });

    test('findMatchInScript handles single words if length >= 2', () {
      const script = "Premièrement, nous devons analyser la situation.";
      final tokens = tokenizeScript(script);

      final match = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: ['analyser'],
        currentIndex: 0,
      );
      expect(match, isNotNull);
      expect(tokens[match!].normalized, 'analyser');
    });

    test('findMatchInScript global fallback matches jump across text', () {
      const script =
          "Introduction très longue avec beaucoup de mots ici. Partie deux commence maintenant.";
      final tokens = tokenizeScript(script);

      // Current index at beginning (0), speaker jumps to "commence maintenant"
      final spokenJump = tokenizeSpoken("Partie deux commence maintenant");
      final match = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: spokenJump,
        currentIndex: 0,
      );
      expect(match, isNotNull);
      expect(tokens[match!].normalized, 'maintenant');
    });
  });
}
