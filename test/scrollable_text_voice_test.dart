import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiefprompt/providers/voice_scroll_provider.dart';
import 'package:tiefprompt/ui/widgets/scrollable_text.dart';

/// Voice tracking already running (and the speaker halfway through the text)
/// before [ScrollableText] is mounted — e.g. the widget was recreated because
/// the camera preview got inserted into the prompter's Stack.
class _AlreadyListeningVoiceScroll extends VoiceScrollNotifier {
  @override
  VoiceScrollState build() => const VoiceScrollState(
    isListening: true,
    isSpeaking: true,
    scrollProgress: 0.5,
    matchedWordIndex: 100,
    totalWords: 200,
  );
}

/// Speaker has just said the word "Bonjour" (characters 0..7 of the script).
class _MatchedFirstWordVoiceScroll extends VoiceScrollNotifier {
  @override
  VoiceScrollState build() => const VoiceScrollState(
    isListening: true,
    isSpeaking: true,
    matchedWordIndex: 0,
    totalWords: 3,
    highlightStart: 0,
    highlightEnd: 7,
  );
}

String _lines(int count) =>
    List.generate(count, (i) => 'Ligne numéro $i du texte.').join('\n\n');

/// Speaker is reading line 150 of [_lines] (200).
class _ReadingLine150VoiceScroll extends VoiceScrollNotifier {
  static final text = _lines(200);
  static final start = text.indexOf('Ligne numéro 150 ');

  @override
  VoiceScrollState build() => VoiceScrollState(
    isListening: true,
    isSpeaking: true,
    scrollProgress: start / text.length,
    matchedWordIndex: 750,
    totalWords: 1000,
    highlightStart: start,
    highlightEnd: start + 5,
  );
}

Widget _prompter(
  ScrollableTextController controller,
  String text,
  VoiceScrollNotifier Function() voiceScroll,
) {
  return ProviderScope(
    overrides: [voiceScrollProvider.overrideWith(voiceScroll)],
    child: MaterialApp(
      home: Scaffold(
        body: ScrollableText(
          controller: controller,
          text: text,
          style: const TextStyle(fontSize: 20),
          sideMargin: 16,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'voice scroll moves the text when listening started before mount',
    (tester) async {
      final controller = ScrollableTextController();
      addTearDown(controller.dispose);

      final text = List.generate(200, (i) => 'Ligne numéro $i du texte.').join('\n\n');

      await tester.pumpWidget(
        _prompter(controller, text, _AlreadyListeningVoiceScroll.new),
      );

      final initialOffset = controller.scrollController.offset;

      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(controller.scrollController.offset, greaterThan(initialOffset));
    },
  );

  testWidgets('voice-matched word settles on the reading line at the top', (
    tester,
  ) async {
    final controller = ScrollableTextController();
    addTearDown(controller.dispose);

    final text = _ReadingLine150VoiceScroll.text;
    await tester.pumpWidget(
      _prompter(controller, text, _ReadingLine150VoiceScroll.new),
    );
    // ~9000 px to cover from the top of the text, at up to 900 px/s.
    for (var i = 0; i < 900; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final paragraphFinder = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == text,
    );
    final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: _ReadingLine150VoiceScroll.start),
      Rect.zero,
    );
    final wordTopOnScreen = paragraph.localToGlobal(caret).dy;

    // Test viewport: the whole 600 px high test screen; reading line at 8 %.
    expect(wordTopOnScreen, closeTo(600 * 0.08, 2));
  });

  testWidgets('voice-matched word is highlighted in the scrolling text', (
    tester,
  ) async {
    final controller = ScrollableTextController();
    addTearDown(controller.dispose);

    const text = 'Bonjour à tous';
    await tester.pumpWidget(
      _prompter(controller, text, _MatchedFirstWordVoiceScroll.new),
    );

    final paragraph = tester.widget<RichText>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == text,
      ),
    );

    final highlighted = <String>[];
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && span.style?.backgroundColor != null) {
        highlighted.add(span.text ?? '');
      }
      return true;
    });

    expect(highlighted, ['Bonjour']);
  });
}
