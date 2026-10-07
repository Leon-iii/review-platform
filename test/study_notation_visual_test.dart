import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_list/question_management_card.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

// Opt-in screenshots are generated under ignored build/, never golden baselines.
const _capture = bool.fromEnvironment('CAPTURE_STUDY_NOTATION');

void main() {
  setUpAll(() async {
    if (!_capture) return;
    final korean = FontLoader('NotationReview');
    final bytes = await File('C:/Windows/Fonts/malgun.ttf').readAsBytes();
    korean.addFont(Future.value(ByteData.sublistView(bytes)));
    await korean.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final (family, file) in [
      ('KaTeX_Main', 'KaTeX_Main-Regular.ttf'),
      ('KaTeX_Math', 'KaTeX_Math-Italic.ttf'),
      ('KaTeX_AMS', 'KaTeX_AMS-Regular.ttf'),
      ('KaTeX_Size1', 'KaTeX_Size1-Regular.ttf'),
      ('KaTeX_Size2', 'KaTeX_Size2-Regular.ttf'),
    ]) {
      final loader = FontLoader('packages/flutter_math_fork/$family');
      loader.addFont(
        rootBundle.load(
          'packages/flutter_math_fork/lib/katex_fonts/fonts/$file',
        ),
      );
      await loader.load();
    }
  });

  for (final (width, scale, dark) in [
    (720.0, 1.0, false),
    (360.0, 2.0, true),
  ]) {
    testWidgets('실제 문제 카드 수식 레이아웃 $width/$scale/dark=$dark', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      final question = Question(
        id: 'notation-question',
        folderId: 'folder',
        type: QuestionType.multipleChoice,
        status: QuestionStatus.approved,
        prompt: r'성능 (Performance) \(\mathrm{Performance}_{X}\)의 정의는 무엇인가?',
        explanation: r'실행 시간 (Execution time)이 \(T_{X}\)이면 \[\mathrm{Performance}_{X} = \frac{1}{T_{X}}\]이다.',
        choices: const [
          QuestionChoice(
            id: 'c1',
            position: 0,
            text: r'\(\frac{1}{T_{X}}\)이다.',
            isCorrect: true,
          ),
          QuestionChoice(
            id: 'c2',
            position: 1,
            text: r'\(T_{X}^{2}\)이다.',
            isCorrect: false,
          ),
        ],
        acceptableAnswers: const [],
        difficulty: 2,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      var theme = dark ? AppTheme.dark : AppTheme.light;
      if (_capture) {
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'NotationReview'),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const StudyText(
                            r'위·아랫첨자: \(a_{i,j}^{(k)}\), \(x^{2}\), \(x_{2}\)',
                          ),
                          const SizedBox(height: 16),
                          QuestionManagementCard(
                            question: question,
                            onAction: (_) {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('question-prompt-notation-question')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (_capture) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('build/notation-review');
          await directory.create(recursive: true);
          await File(
            '${directory.path}/math-${width.toInt()}-${scale.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
