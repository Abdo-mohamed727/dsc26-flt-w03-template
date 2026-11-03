import 'dart:async';

import 'package:dsc26_flt_w03/app.dart';
import 'package:dsc26_flt_w03/data/repositories/practice_repository.dart';
import 'package:dsc26_flt_w03/data/services/api_failure.dart';
import 'package:dsc26_flt_w03/data/services/question_api.dart';
import 'package:dsc26_flt_w03/domain/models/question.dart';
import 'package:dsc26_flt_w03/utils/result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Question _question(String id) => Question(
  id: id,
  skillId: 'chem.moles',
  stem: 'ما ناتج ٢ + ٢؟',
  choices: ['٣', '٤', '٥'],
);

/// Scripted repository: each [nextQuestions] call returns the next result.
class ScriptedRepository extends PracticeRepository {
  ScriptedRepository(this.script) : super(api: _NoopApi(), sleep: (_) async {});

  final List<Result<List<Question>>> script;
  int calls = 0;
  Completer<void>? _gate;

  @override
  Future<Result<List<Question>>> nextQuestions(String studentId) async {
    calls++;
    if (calls > script.length) {
      throw StateError('unexpected extra repository call');
    }
    final gate = Completer<void>();
    _gate = gate;
    await gate.future; // keep every request pending until the test opens it
    return script[calls - 1];
  }

  void respond() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
      _gate = null;
    }
  }
}

class _NoopApi implements QuestionApi {
  @override
  Future<Result<List<Question>>> fetchNext({
    required String studentId,
    int limit = 10,
  }) async => Err(const BadResponse('not used'));
}

void main() {
  group('initial loading', () {
    testWidgets('shows a loading indicator while the request is pending', (
      tester,
    ) async {
      final repo = ScriptedRepository([
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      expect(find.byKey(const Key('practice-loading')), findsOneWidget);
    });

    testWidgets('the initial request happens exactly once', (tester) async {
      final repo = ScriptedRepository([
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      await tester.pump();
      await tester.pump();
      expect(repo.calls, 1);
    });

    testWidgets('a successful response displays the questions', (tester) async {
      final repo = ScriptedRepository([
        Ok([_question('q1'), _question('q2')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('question-q1')), findsOneWidget);
      expect(find.byKey(const Key('question-q2')), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  group('empty state', () {
    testWidgets('an empty response shows the exact completion message', (
      tester,
    ) async {
      final repo = ScriptedRepository([Ok([])]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-empty')), findsOneWidget);
      expect(find.text("you have finished today's practice"), findsOneWidget);
    });

    testWidgets('an empty response does not show a failure view', (
      tester,
    ) async {
      final repo = ScriptedRepository([Ok([])]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-error')), findsNothing);
      expect(find.byKey(const Key('practice-retry')), findsNothing);
    });
  });

  group('failure state', () {
    testWidgets('an ordinary failure shows a friendly retry button', (
      tester,
    ) async {
      final repo = ScriptedRepository([Err(ServerError(500))]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-error')), findsOneWidget);
      expect(find.byKey(const Key('practice-retry')), findsOneWidget);
    });

    testWidgets('Unauthorized shows a sign-in button instead of retry', (
      tester,
    ) async {
      final repo = ScriptedRepository([Err(Unauthorized())]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-signin')), findsOneWidget);
      expect(find.byKey(const Key('practice-retry')), findsNothing);
    });

    testWidgets('no visible text contains Exception', (tester) async {
      final repo = ScriptedRepository([
        Err(Offline()),
        Err(const BadResponse('x')),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  group('refresh', () {
    testWidgets('the refresh action exists in every state', (tester) async {
      for (final script in [
        <Result<List<Question>>>[Err(ServerError(500))],
        <Result<List<Question>>>[Ok([])],
        <Result<List<Question>>>[
          Ok([_question('q1')]),
        ],
      ]) {
        final repo = ScriptedRepository(script);
        await tester.pumpWidget(buildPracticeApp(repository: repo));
        repo.respond();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('practice-refresh')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('refresh requests updated questions', (tester) async {
      final repo = ScriptedRepository([
        Ok([]),
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-empty')), findsOneWidget);

      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.pump();
      expect(find.byKey(const Key('practice-refreshing')), findsNothing);
      expect(repo.calls, 2);
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('question-q1')), findsOneWidget);
    });

    testWidgets('two rapid refresh taps produce only one request', (
      tester,
    ) async {
      final repo = ScriptedRepository([
        Ok([_question('q1')]),
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.pump();
      expect(repo.calls, 2); // initial + a single refresh
      repo.respond();
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
    });

    testWidgets('refresh works after a failure', (tester) async {
      final repo = ScriptedRepository([
        Err(ServerError(500)),
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('practice-refresh')));
      repo.respond();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('question-q1')), findsOneWidget);
    });
  });

  group('lifecycle safety', () {
    testWidgets('disposing during the initial load does not throw', (
      tester,
    ) async {
      final repo = ScriptedRepository([
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      await tester.pumpWidget(const SizedBox());
      repo.respond();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposing during refresh does not throw', (tester) async {
      final repo = ScriptedRepository([
        Ok([]),
        Ok([_question('q1')]),
      ]);
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      repo.respond();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.pumpWidget(const SizedBox());
      repo.respond();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
