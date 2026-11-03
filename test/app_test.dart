import 'dart:async';
import 'dart:convert';

import 'package:dsc26_flt_w03/app.dart';
import 'package:dsc26_flt_w03/data/repositories/practice_repository.dart';
import 'package:dsc26_flt_w03/data/services/question_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final base = Uri.parse('https://api.masaraat.test');

Map<String, Object?> q(String id) => {
  'id': id,
  'skillId': 'chem.moles',
  'stem': 'كم عدد المولات؟',
  'choices': ['1', '2', '3', '4'],
};

http.Response ok(List<Map<String, Object?>> questions) => http.Response.bytes(
  utf8.encode(jsonEncode({'questions': questions})),
  200,
  headers: {'content-type': 'application/json'},
);

PracticeRepository repoWith(
  Future<http.Response> Function(http.Request) fn, {
  Future<void> Function(Duration)? sleep,
}) => PracticeRepository(
  api: QuestionApi(client: MockClient(fn), baseUrl: base),
  sleep: sleep ?? (d) async {},
);

void main() {
  testWidgets(
    'shows a loading indicator until the server answers, then shows questions',
    (tester) async {
      final gate = Completer<http.Response>();
      var calls = 0;
      final repo = repoWith((_) {
        calls++;
        return gate.future;
      });
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      await tester.pump();
      expect(find.byKey(const Key('practice-loading')), findsOneWidget);
      expect(calls, 1);
      gate.complete(ok([q('q1')]));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('question-q1')), findsOneWidget);
      expect(calls, 1); // no duplicate initial request
    },
  );

  testWidgets(
    'empty response shows the exact completion message, not a failure',
    (tester) async {
      final repo = repoWith((_) async => ok([]));
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('practice-empty')), findsOneWidget);
      expect(find.text("you have finished today's practice"), findsOneWidget);
      expect(find.byKey(const Key('practice-error')), findsNothing);
    },
  );

  testWidgets('failure shows a friendly message and a retry button', (
    tester,
  ) async {
    final repo = repoWith((_) async => http.Response('busy', 503));
    await tester.pumpWidget(buildPracticeApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('practice-error')), findsOneWidget);
    expect(find.byKey(const Key('practice-retry')), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    // The retry itself must be free of the word too.
    for (final t in find.byType(Text).evaluate()) {
      expect((t.widget as Text).data, isNot(contains('Exception')));
    }
  });

  testWidgets('unauthorized shows a sign-in button instead of retry', (
    tester,
  ) async {
    final repo = repoWith((_) async => http.Response('who?', 401));
    await tester.pumpWidget(buildPracticeApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('practice-signin')), findsOneWidget);
    expect(find.byKey(const Key('practice-retry')), findsNothing);
  });

  testWidgets('refresh exists in every state and reloads', (tester) async {
    var fail = true;
    final repo = repoWith((_) async {
      if (fail) return http.Response('boom', 500);
      return ok([q('q1')]);
    });
    await tester.pumpWidget(buildPracticeApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('practice-refresh')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const Key('practice-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('question-q1')), findsOneWidget);
  });

  testWidgets(
    'refresh is disabled while loading; two rapid taps = one request',
    (tester) async {
      final gate = Completer<http.Response>();
      var calls = 0;
      final repo = repoWith((_) async {
        calls++;
        return gate.future;
      });
      await tester.pumpWidget(buildPracticeApp(repository: repo));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('practice-refresh')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('practice-refresh')));
      await tester.pump();
      gate.complete(ok([]));
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );

  testWidgets('disposing during a pending request or retry wait is safe', (
    tester,
  ) async {
    // 1. Pending initial request.
    final gate = Completer<http.Response>();
    final repo = repoWith((_) => gate.future);
    await tester.pumpWidget(buildPracticeApp(repository: repo));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    gate.complete(ok([q('q1')]));
    await tester.pumpAndSettle();

    // 2. Pending refresh after the retry delay is still running.
    var waited = Completer<void>();
    final repo2 = PracticeRepository(
      api: QuestionApi(
        client: MockClient((_) async => http.Response('boom', 503)),
        baseUrl: base,
      ),
      sleep: (d) => waited.future,
    );
    await tester.pumpWidget(buildPracticeApp(repository: repo2));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    waited.complete();
    await tester.pumpAndSettle();
  });
}
