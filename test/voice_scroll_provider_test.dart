import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
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
      expect(state.infoMessage, isNull);
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

    test('findMatchInScript accepts a single word among the next expected words', () {
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

    test('wordsFuzzyEqual does not falsely match words sharing only 4-letter root', () {
      expect(wordsFuzzyEqual('pour', 'pourquoi'), isFalse);
      expect(wordsFuzzyEqual('part', 'particulier'), isFalse);
      expect(wordsFuzzyEqual('jour', 'journaliste'), isFalse);
      // Valid plurals/gender variations differing by at most 2 letters still match
      expect(wordsFuzzyEqual('presentation', 'presentations'), isTrue);
      expect(wordsFuzzyEqual('grand', 'grande'), isTrue);
      expect(wordsFuzzyEqual('grand', 'grandes'), isTrue);
    });

    test('findMatchInScript does not jump on single French stop words', () {
      const script = "Voici une phrase avec de nombreux mots et de la ponctuation.";
      final tokens = tokenizeScript(script);

      // Single stop word should not trigger a false match jump
      final matchStopWord = findMatchInScript(
        scriptTokens: tokens,
        spokenNormWords: ['de'],
        currentIndex: 0,
      );
      expect(matchStopWord, isNull);
    });

    test('handleSpeechError replaces audio timeout with informational waiting message', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(voiceScrollProvider.notifier);

      // 1. error_speech_timeout
      notifier.handleSpeechError(SpeechRecognitionError('error_speech_timeout', false));
      var state = container.read(voiceScrollProvider);
      expect(state.errorMessage, isNull);
      expect(state.infoMessage, 'En attente du texte...');
      expect(state.isSpeaking, isFalse);

      // 2. error_audio
      notifier.handleSpeechError(SpeechRecognitionError('error_audio', false));
      state = container.read(voiceScrollProvider);
      expect(state.errorMessage, isNull);
      expect(state.infoMessage, 'En attente du texte...');

      // 3. custom timeout audio message
      notifier.handleSpeechError(SpeechRecognitionError('timeout audio', false));
      state = container.read(voiceScrollProvider);
      expect(state.errorMessage, isNull);
      expect(state.infoMessage, 'En attente du texte...');

      // 4. Permission error sets friendly French message
      notifier.handleSpeechError(SpeechRecognitionError('error_permission', true));
      state = container.read(voiceScrollProvider);
      expect(state.errorMessage, 'Permission microphone requise pour le suivi vocal.');
    });

    test('handleSpeechError surfaces a persistent microphone failure once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(voiceScrollProvider.notifier);
      // Android reports ERROR_AUDIO as 'error_audio_error', always permanent.
      final audioError = SpeechRecognitionError('error_audio_error', true);

      notifier.handleSpeechError(audioError);
      notifier.handleSpeechError(audioError);
      expect(container.read(voiceScrollProvider).errorMessage, isNull);

      notifier.handleSpeechError(audioError);
      expect(
        container.read(voiceScrollProvider).errorMessage,
        contains('Microphone indisponible'),
      );

      // Not re-raised on every further retry (the screen clears it after display).
      notifier.clearError();
      notifier.handleSpeechError(audioError);
      expect(container.read(voiceScrollProvider).errorMessage, isNull);
    });

    group('sliding search zone', () {
      // Paragraph 3 reuses words of paragraph 1 a few dozen words later.
      final script = [
        "Aujourd'hui je vous présente le projet Souffleur, un prompteur libre.",
        List.filled(
          3,
          'Ensuite nous verrons comment il fonctionne en pratique.',
        ).join(' '),
        'Enfin le projet Souffleur sera disponible de la manière la plus simple.',
      ].join('\n\n');
      final tokens = tokenizeScript(script);
      // Reader is on "prompteur", in paragraph 1.
      final current = tokens.indexWhere((t) => t.normalized == 'prompteur');

      void expectNoJump(String spoken) {
        final match = findMatchInScript(
          scriptTokens: tokens,
          spokenNormWords: tokenizeSpoken(spoken),
          currentIndex: current,
        );
        expect(
          match == null || match <= current + 3,
          isTrue,
          reason: '"$spoken" jumped to word $match (${match == null ? '' : tokens[match].raw})',
        );
      }

      test('a repeated single word does not jump to a later paragraph', () {
        // Mis-heard word followed by "projet", which reappears in paragraph 3.
        expectNoJump('ceci projet');
      });

      test('two common words do not jump to a later paragraph', () {
        expectNoJump('voilà de la');
      });

      test('a repeated two-word phrase does not jump to a later paragraph', () {
        expectNoJump('le projet');
      });

      test('a far jump is only followed once two results agree on it', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(voiceScrollProvider.notifier);

        final longScript = [
          'Introduction du sujet avec quelques mots.',
          List.filled(
            8,
            'Un passage intermédiaire assez long pour sortir de la zone.',
          ).join(' '),
          'Enfin le projet Souffleur sera disponible pour tous.',
        ].join('\n\n');
        final longTokens = tokenizeScript(longScript);
        notifier.debugLoadScript(longScript);

        // Reader skipped to the last paragraph: one result is not enough...
        notifier.debugSpeechResult('enfin le projet Souffleur');
        expect(container.read(voiceScrollProvider).matchedWordIndex, 0);

        // ...a second one agreeing on the same place is.
        notifier.debugSpeechResult('enfin le projet Souffleur sera');
        final matched = container.read(voiceScrollProvider).matchedWordIndex;
        expect(longTokens[matched].normalized, 'sera');
      });

      test('the next words of the current sentence still match', () {
        final match = findMatchInScript(
          scriptTokens: tokens,
          spokenNormWords: tokenizeSpoken('un prompteur libre'),
          currentIndex: current,
        );
        expect(match, isNotNull);
        expect(tokens[match!].normalized, 'libre');
      });
    });

    test('network errors pause quietly instead of a red error', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(voiceScrollProvider.notifier);

      for (final code in ['error_network', 'error_network_timeout', 'error_server']) {
        notifier.handleSpeechError(SpeechRecognitionError(code, true));
        final state = container.read(voiceScrollProvider);
        expect(state.errorMessage, isNull, reason: code);
        expect(state.offline, isTrue, reason: code);
      }

      notifier.debugLoadScript('Bonjour à tous');
      notifier.debugSpeechResult('bonjour');
      expect(container.read(voiceScrollProvider).offline, isFalse);
    });

    test('tapping an already-read word moves back and ignores stale words', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(voiceScrollProvider.notifier);

      const script =
          "Nous allons parler du projet Souffleur aujourd'hui avec vous tous";
      final tokens = tokenizeScript(script);
      String current() =>
          tokens[container.read(voiceScrollProvider).matchedWordIndex].normalized;

      notifier.debugLoadScript(script);
      notifier.debugSpeechResult('nous allons parler du projet souffleur');
      expect(current(), 'souffleur');

      // Reader stumbled and taps "parler" to start again from there.
      final parler = script.indexOf('parler');
      expect(notifier.moveBackToCharOffset(parler + 2), isTrue);
      final state = container.read(voiceScrollProvider);
      expect(current(), 'parler');
      expect(state.highlightStart, parler);
      expect(state.realignTrigger, 1);

      // Words heard before the tap do not drag the position forward again...
      notifier.debugSpeechResult('nous allons parler du projet souffleur');
      expect(current(), 'parler');

      // ...while the words read again from the tapped one do.
      notifier.debugSpeechResult(
        'nous allons parler du projet souffleur parler du projet',
      );
      expect(current(), 'projet');

      // Words not read yet cannot be tapped.
      expect(notifier.moveBackToCharOffset(script.indexOf('vous')), isFalse);
    });

    test('pickFrenchLocaleId prefers France French over other variants', () {
      // Recognizers list variants alphabetically, so fr-BE comes first.
      expect(
        pickFrenchLocaleId(['en-US', 'fr-BE', 'fr-CA', 'fr-FR']),
        'fr-FR',
      );
      expect(pickFrenchLocaleId(['fr_BE', 'fr_FR']), 'fr_FR');
      expect(
        pickFrenchLocaleId(['fr-BE', 'fr-CH'], systemLocaleId: 'fr-CH'),
        'fr-CH',
      );
      expect(pickFrenchLocaleId(['en-US', 'fr-CA']), 'fr-CA');
      expect(pickFrenchLocaleId(['en-US']), 'fr_FR');
    });

    test('normalizeSoundLevel maps recognizer RMS dB to 0..1', () {
      expect(normalizeSoundLevel(-10), 0.0);
      expect(normalizeSoundLevel(-2), 0.0);
      expect(normalizeSoundLevel(4), closeTo(0.5, 1e-9));
      expect(normalizeSoundLevel(10), 1.0);
      expect(normalizeSoundLevel(20), 1.0);
    });

    test('realignToLastMatch increments realignTrigger', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(voiceScrollProvider.notifier);
      expect(container.read(voiceScrollProvider).realignTrigger, 0);

      notifier.realignToLastMatch();
      expect(container.read(voiceScrollProvider).realignTrigger, 1);

      notifier.realignToLastMatch();
      expect(container.read(voiceScrollProvider).realignTrigger, 2);
    });
  });
}
