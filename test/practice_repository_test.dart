import 'package:dsc26_flt_w03/data/repositories/practice_repository.dart';
import 'package:dsc26_flt_w03/data/services/api_failure.dart';
import 'package:dsc26_flt_w03/data/services/question_api.dart';
import 'package:dsc26_flt_w03/domain/models/question.dart';
import 'package:dsc26_flt_w03/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake QuestionApi whose scripted results are returned one call at a time.
class FakeApi implements QuestionApi {
  FakeApi(this.script);

  final List<Result<List<Question>>> script;
  int calls = 0;

  @override
  Future<Result<List<Question>>> fetchNext({
    required String studentId,
    int limit = 10,
  }) async {
    if (calls >= script.length) {
      throw StateError('unexpected extra API call');
    }
    return script[calls++];
  }
}

Result<List<Question>> okOne() => Ok([
  Question(id: 'q1', skillId: 's', stem: 'stem', choices: ['a', 'b']),
]);

Result<List<Question>> err(ApiFailure failure) => Err(failure);

PracticeRepository repoOf(
  FakeApi api,
  List<Duration> sleeps, {
  int maxRetries = 2,
}) => PracticeRepository(
  api: api,
  sleep: (d) async => sleeps.add(d),
  maxRetries: maxRetries,
);

void main() {
  group('success', () {
    test('first request succeeds: one call, no sleep', () async {
      final api = FakeApi([okOne()]);
      final sleeps = <Duration>[];
      final result = await repoOf(api, sleeps).nextQuestions('s1');
      expect(result, isA<Ok<List<Question>>>());
      expect(api.calls, 1);
      expect(sleeps, isEmpty);
    });

    test('success after one retry', () async {
      final api = FakeApi([err(Offline()), okOne()]);
      final sleeps = <Duration>[];
      final result = await repoOf(api, sleeps).nextQuestions('s1');
      expect(result, isA<Ok<List<Question>>>());
      expect(api.calls, 2);
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('success after multiple retries', () async {
      final api = FakeApi([err(ServerError(500)), err(TimedOut()), okOne()]);
      final sleeps = <Duration>[];
      final result = await repoOf(api, sleeps).nextQuestions('s1');
      expect(result, isA<Ok<List<Question>>>());
      expect(api.calls, 3);
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });
  });

  group('transient failures are retried', () {
    final cases = {
      'Offline': err(Offline()),
      'TimedOut': err(TimedOut()),
      'ServerError': err(ServerError(500)),
      'RateLimited': err(RateLimited(const Duration(seconds: 3))),
    };
    cases.forEach((name, failure) {
      test('$name is retried and then succeeds', () async {
        final api = FakeApi([failure, okOne()]);
        final sleeps = <Duration>[];
        final result = await repoOf(api, sleeps).nextQuestions('s1');
        expect(result, isA<Ok<List<Question>>>());
        expect(api.calls, 2);
        expect(sleeps, isNotEmpty);
      });
    });

    test('default exponential delays are exactly 1, 2, 4 seconds', () async {
      final api = FakeApi([
        err(Offline()),
        err(ServerError(503)),
        err(TimedOut()),
        okOne(),
      ]);
      final sleeps = <Duration>[];
      await repoOf(api, sleeps, maxRetries: 3).nextQuestions('s1');
      expect(api.calls, 4);
      expect(sleeps, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });
  });

  group('rate limiting', () {
    test('retryAfter replaces exponential backoff', () async {
      final api = FakeApi([
        err(RateLimited(const Duration(seconds: 7))),
        okOne(),
      ]);
      final sleeps = <Duration>[];
      await repoOf(api, sleeps).nextQuestions('s1');
      expect(sleeps, [const Duration(seconds: 7)]);
    });

    test('retryAfter greater than 30s is capped at 30s', () async {
      final api = FakeApi([
        err(RateLimited(const Duration(seconds: 90))),
        okOne(),
      ]);
      final sleeps = <Duration>[];
      await repoOf(api, sleeps).nextQuestions('s1');
      expect(sleeps, [const Duration(seconds: 30)]);
    });

    test(
      'RateLimited then ServerError uses the different correct delays',
      () async {
        final api = FakeApi([
          err(RateLimited(const Duration(seconds: 7))),
          err(ServerError(500)),
          okOne(),
        ]);
        final sleeps = <Duration>[];
        await repoOf(api, sleeps).nextQuestions('s1');
        expect(api.calls, 3);
        expect(sleeps, [
          const Duration(seconds: 7),
          const Duration(seconds: 2),
        ]);
      },
    );
  });

  group('permanent failures', () {
    final cases = <String, ApiFailure>{
      'Unauthorized': Unauthorized(),
      'NotFound': NotFound(),
      'BadResponse': const BadResponse('bad'),
      'UnexpectedStatus': UnexpectedStatus(418),
    };
    cases.forEach((name, failure) {
      test('$name is returned immediately with no sleep', () async {
        final api = FakeApi([err(failure), okOne()]);
        final sleeps = <Duration>[];
        final result = await repoOf(api, sleeps).nextQuestions('s1');
        expect((result as Err<List<Question>>).failure, equals(failure));
        expect(api.calls, 1);
      });
    });
  });

  group('retry limits', () {
    test('default configuration makes at most 3 API calls', () async {
      final api = FakeApi([
        err(Offline()),
        err(Offline()),
        err(Offline()),
        okOne(),
      ]);
      final sleeps = <Duration>[];
      final result = await repoOf(api, sleeps).nextQuestions('s1');
      expect(api.calls, 3);
      expect((result as Err<List<Question>>).failure, isA<Offline>());
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test('maxRetries = 0 makes exactly one call and no sleep', () async {
      final api = FakeApi([err(Offline()), okOne()]);
      final sleeps = <Duration>[];
      final result = await repoOf(
        api,
        sleeps,
        maxRetries: 0,
      ).nextQuestions('s1');
      expect(api.calls, 1);
      expect(sleeps, isEmpty);
      expect((result as Err<List<Question>>).failure, isA<Offline>());
    });

    test('custom maxRetries is respected', () async {
      final api = FakeApi([err(Offline()), err(Offline()), okOne()]);
      final sleeps = <Duration>[];
      final result = await repoOf(
        api,
        sleeps,
        maxRetries: 4,
      ).nextQuestions('s1');
      expect(result, isA<Ok<List<Question>>>());
      expect(api.calls, 3);
    });

    test(
      'the last failure is returned unchanged when retries are exhausted',
      () async {
        final Err<List<Question>> last = Err(ServerError(503));
        final api = FakeApi([err(Offline()), err(TimedOut()), last]);
        final sleeps = <Duration>[];
        final result = await repoOf(api, sleeps).nextQuestions('s1');
        expect((result as Err<List<Question>>).failure, equals(last.failure));
        expect(api.calls, 3);
      },
    );

    test('no sleep occurs after the final attempt', () async {
      final api = FakeApi([err(Offline()), err(Offline()), err(Offline())]);
      final sleeps = <Duration>[];
      await repoOf(api, sleeps).nextQuestions('s1');
      // 2 sleeps for 2 retries; nothing after the third (final) call.
      expect(sleeps.length, 2);
      expect(api.calls, 3);
    });
  });
}
