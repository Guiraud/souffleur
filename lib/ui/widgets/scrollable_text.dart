import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tief_weave/markdown.dart';
import 'package:tiefprompt/providers/current_chapter_provider.dart';
import 'package:tiefprompt/providers/prompter_provider.dart';
import 'package:tiefprompt/providers/voice_scroll_provider.dart';

class _UserScrolling extends Notifier<bool> {
  @override
  bool build() => false;
  void setValue(bool v) => state = v;
}

final _userScrollingProvider = NotifierProvider<_UserScrolling, bool>(
  _UserScrolling.new,
);

class ScrollableTextController {
  final ScrollController scrollController;

  ScrollableTextController({double initialScrollOffset = 0.0})
    : scrollController = ScrollController(
        initialScrollOffset: initialScrollOffset,
      );

  void jumpTo(double offset) {
    scrollController.jumpTo(offset);
  }

  void jumpRelative(double offset) {
    scrollController.jumpTo(scrollController.offset + offset);
  }

  void dispose() {
    scrollController.dispose();
  }
}

class ScrollableText extends ConsumerStatefulWidget {
  final ScrollableTextController controller;
  final String text;
  final TextStyle? style;
  final double sideMargin;

  const ScrollableText({
    super.key,
    required this.text,
    this.style,
    required this.sideMargin,
    required this.controller,
  });

  @override
  ConsumerState<ScrollableText> createState() => _ScrollableTextState();
}

class _ScrollableTextState extends ConsumerState<ScrollableText>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _scrollSpeed = 0;
  Duration _lastElapsed = Duration.zero;
  Function? _onReachedEnd;

  MarkdownAst _ast = const MarkdownAst.empty();
  final MarkdownRendererController _markdownController =
      MarkdownRendererController();
  List<({String title, double offset})> _chapterOffsets = [];
  double _topPadding = 0;
  double _mediaHeight = 0;

  void _checkScrollingState() {
    final isPlaying = ref.read(prompterProvider).isPlaying;
    final isVoiceListening = ref.read(voiceScrollProvider).isListening;
    final speed = ref.read(prompterProvider).config.scrollSpeed;
    _scrollSpeed = speed;

    if (isPlaying || isVoiceListening) {
      if (!(_ticker?.isActive ?? false)) {
        _lastElapsed = Duration.zero;
        _ticker?.start();
      }
    } else {
      _stopScrolling();
    }
  }

  void _stopScrolling() {
    _ticker?.stop();
  }

  @override
  void initState() {
    super.initState();

    _onReachedEnd = () {
      ref.read(prompterProvider.notifier).togglePlayPause();
      if (ref.read(voiceScrollProvider).isListening) {
        ref.read(voiceScrollProvider.notifier).stopListening();
      }
    };

    _ticker = createTicker((Duration elapsed) {
      _tick(elapsed);
    });

    _rebuildAst();

    _markdownController.addListener(_recomputeChapterOffsets);
    widget.controller.scrollController.addListener(_updateCurrentChapter);

    // The ref.listen callbacks in build only fire on *changes*. If playback or
    // voice tracking is already active when this widget is (re)created — e.g.
    // the camera preview was inserted into the prompter Stack — nothing would
    // ever start the ticker, so sync with the current state once mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A drag interrupted by a rebuild never delivers its ScrollEndNotification.
      ref.read(_userScrollingProvider.notifier).setValue(false);
      _checkScrollingState();
    });
  }

  @override
  void didUpdateWidget(covariant ScrollableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _rebuildAst();
    }
  }

  void _rebuildAst() {
    _ast = MarkdownAstBuilder().build(MarkdownTokenizer().parse(widget.text));
    _chapterOffsets = [];
  }

  void _recomputeChapterOffsets() {
    final blocks = _ast.document.blocks;
    _chapterOffsets = [
      for (var i = 0; i < blocks.length; i++)
        if (blocks[i] case final Heading heading)
          if (_markdownController.offsetOf(i) case final double offset)
            (
              title: _inlinesToText(heading.inlines),
              offset: offset + _topPadding,
            ),
    ];
    _updateCurrentChapter();
  }

  String _inlinesToText(List<Inline> inlines) {
    return inlines
        .map(
          (inline) => switch (inline) {
            PlainText(:final text) => text,
            Emphasis(:final children) => _inlinesToText(children),
            Strong(:final children) => _inlinesToText(children),
            Underline(:final children) => _inlinesToText(children),
          },
        )
        .join();
  }

  void _updateCurrentChapter() {
    final (:markdownEnabled, :showCurrentChapter) = ref.read(
      prompterProvider.select(
        (s) => (
          markdownEnabled: s.config.markdownEnabled,
          showCurrentChapter: s.config.showCurrentChapter,
        ),
      ),
    );
    if (!showCurrentChapter || !markdownEnabled) {
      return;
    }

    final offset = widget.controller.scrollController.offset;
    String? current;
    for (final chapter in _chapterOffsets) {
      if (chapter.offset <= offset) {
        current = chapter.title;
      } else {
        break;
      }
    }

    ref.read(currentChapterProvider.notifier).setValue(current);
  }

  void _tick(Duration elapsed) {
    final deltaSeconds =
        (elapsed - _lastElapsed).inMicroseconds /
        Duration.microsecondsPerSecond;
    _lastElapsed = elapsed;

    if (deltaSeconds <= 0 || deltaSeconds > 0.5) return;

    final isUserScrolling = ref.read(_userScrollingProvider);
    if (!widget.controller.scrollController.hasClients || isUserScrolling) {
      return;
    }

    final voiceState = ref.read(voiceScrollProvider);
    if (voiceState.isListening) {
      _tickVoiceScroll(deltaSeconds, voiceState);
    } else if (ref.read(prompterProvider).isPlaying) {
      _tickManualScroll(deltaSeconds);
    }
  }

  void _tickManualScroll(double deltaSeconds) {
    final calculatedScrollOffset =
        _getScrollOffsetInLinesPerSecond(_scrollSpeed) * deltaSeconds;

    final controller = widget.controller.scrollController;
    if (controller.position.pixels + calculatedScrollOffset >=
        controller.position.maxScrollExtent) {
      _onReachedEnd?.call();
      return;
    }
    controller.jumpTo(controller.position.pixels + calculatedScrollOffset);
  }

  void _tickVoiceScroll(double deltaSeconds, VoiceScrollState voiceState) {
    final controller = widget.controller.scrollController;
    final maxScroll = controller.position.maxScrollExtent;
    final mediaH = _mediaHeight > 0 ? _mediaHeight : 800.0;
    final textHeight = (maxScroll - mediaH).clamp(0.0, double.infinity);

    // Reading eye-line is at 40% from top of screen (comfortable reading height near camera)
    final readingY = mediaH * 0.40;
    final startScroll = mediaH - readingY;
    final targetPixels =
        (startScroll + voiceState.scrollProgress * textHeight).clamp(0.0, maxScroll);
    final currentPixels = controller.position.pixels;
    final distance = targetPixels - currentPixels;

    if (currentPixels >= maxScroll && targetPixels >= maxScroll - 10) {
      _onReachedEnd?.call();
      return;
    }

    if (voiceState.isSpeaking) {
      if (distance > 0) {
        // Target is ahead: scale speed dynamically with distance
        // The faster the user speaks, the further ahead target moves, and the faster it rolls!
        final catchUpSpeed = (distance * 3.5).clamp(35.0, 850.0);
        final advance = (catchUpSpeed * deltaSeconds).clamp(0.0, distance);
        controller.jumpTo(currentPixels + advance);
      } else if (distance > -25.0) {
        // Aligned with target: keep rolling smoothly forward at baseline speaking rate
        final baselineSpeed = _getScrollOffsetInLinesPerSecond(1.2);
        final advance = baselineSpeed * deltaSeconds;
        controller.jumpTo((currentPixels + advance).clamp(0.0, targetPixels + 40.0));
      } else if (distance < -50.0) {
        // User skipped backwards in text: smoothly glide backwards to match
        final backSpeed = (distance * 3.5).clamp(-850.0, -35.0);
        final advance = (backSpeed * deltaSeconds).clamp(distance, 0.0);
        controller.jumpTo(currentPixels + advance);
      }
    } else {
      // User paused speaking (silence > 1.5s)
      if (distance.abs() > 2.0) {
        // Smoothly settle to the target word
        final settleSpeed = (distance.abs() * 3.0).clamp(20.0, 350.0);
        final step = settleSpeed * deltaSeconds;
        final advance = distance > 0
            ? step.clamp(0.0, distance)
            : (-step).clamp(distance, 0.0);
        controller.jumpTo(currentPixels + advance);
      }
      // When distance.abs() <= 2.0, completely settled!
    }
  }

  TextSpan _highlightedText(({int start, int end})? highlight) {
    final text = widget.text;
    if (highlight == null ||
        highlight.start < 0 ||
        highlight.start >= highlight.end ||
        highlight.end > text.length) {
      return TextSpan(text: text);
    }

    // Only the colors change, so highlighting never reflows the text.
    final accent = Theme.of(context).colorScheme.primary;
    return TextSpan(
      children: [
        TextSpan(text: text.substring(0, highlight.start)),
        TextSpan(
          text: text.substring(highlight.start, highlight.end),
          style: TextStyle(color: accent, backgroundColor: accent.withAlpha(60)),
        ),
        TextSpan(text: text.substring(highlight.end)),
      ],
    );
  }

  double _getScrollOffsetInLinesPerSecond(double speed) {
    final textStyle = widget.style ?? const TextStyle(fontSize: 14);
    final lineHeight = textStyle.height ?? 1.0;
    final fontSize = textStyle.fontSize ?? 14.0;
    final lineHeightInPixels = lineHeight * fontSize;

    return speed * lineHeightInPixels;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      prompterProvider.select(
        (p) => (isPlaying: p.isPlaying, speed: p.config.scrollSpeed),
      ),
      (previous, next) {
        _checkScrollingState();
      },
    );

    ref.listen(
      voiceScrollProvider.select((v) => v.isListening),
      (previous, next) {
        _checkScrollingState();
      },
    );

    ref.listen(
      voiceScrollProvider.select((v) => v.realignTrigger),
      (previous, next) {
        if (next > (previous ?? 0) &&
            widget.controller.scrollController.hasClients) {
          final controller = widget.controller.scrollController;
          final maxScroll = controller.position.maxScrollExtent;
          final mediaH = _mediaHeight > 0 ? _mediaHeight : 800.0;
          final textHeight = (maxScroll - mediaH).clamp(0.0, double.infinity);
          final readingY = mediaH * 0.40;
          final startScroll = mediaH - readingY;
          final targetPixels = (startScroll +
                  ref.read(voiceScrollProvider).scrollProgress * textHeight)
              .clamp(0.0, maxScroll);
          controller.animateTo(
            targetPixels,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
      },
    );

    final mediaHeight = MediaQuery.of(context).size.height;
    final mediaWidth = MediaQuery.of(context).size.width;
    _mediaHeight = mediaHeight;
    final renderWidth = mediaWidth - widget.sideMargin * 2;
    _topPadding = mediaHeight;

    final (
      :mirroredX,
      :mirroredY,
      :markdownEnabled,
      :showCurrentChapter,
      :alignment,
    ) = ref.watch(
      prompterProvider.select(
        (p) => (
          mirroredX: p.config.mirroredX,
          mirroredY: p.config.mirroredY,
          markdownEnabled: p.config.markdownEnabled,
          showCurrentChapter: p.config.showCurrentChapter,
          alignment: p.config.alignment,
        ),
      ),
    );

    final highlight = ref.watch(
      voiceScrollProvider.select(
        (v) => v.isListening
            ? (start: v.highlightStart, end: v.highlightEnd)
            : null,
      ),
    );

    if (!markdownEnabled || !showCurrentChapter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(currentChapterProvider.notifier).setValue(null);
      });
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          ref.read(_userScrollingProvider.notifier).setValue(true);
        } else if (notification is ScrollEndNotification) {
          ref.read(_userScrollingProvider.notifier).setValue(false);
        }
        return false;
      },
      child: Transform.flip(
        flipX: mirroredX,
        flipY: mirroredY,
        child: SingleChildScrollView(
          controller: widget.controller.scrollController,
          padding: EdgeInsets.fromLTRB(
            widget.sideMargin,
            mediaHeight,
            widget.sideMargin,
            0,
          ),
          child: Column(
            children: [
              if (markdownEnabled)
                Markdown(
                  widget.text,
                  controller: _markdownController,
                  textAlign: alignment,
                  style: widget.style,
                  width: renderWidth,
                )
              else
                // The markdown renderer takes no per-word style, so the
                // voice-matched word is only highlighted in plain-text mode.
                Text.rich(
                  _highlightedText(highlight),
                  style: widget.style,
                  textAlign: alignment,
                ),
              SizedBox(
                height: mediaHeight,
                child: Center(child: Text("The End", style: widget.style)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopScrolling();
    _ticker?.dispose();
    _ticker = null;
    widget.controller.scrollController.removeListener(_updateCurrentChapter);
    _markdownController.removeListener(_recomputeChapterOffsets);
    _markdownController.dispose();
    super.dispose();
  }
}
