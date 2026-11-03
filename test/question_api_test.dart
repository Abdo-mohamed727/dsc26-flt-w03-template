import 'dart:convert';

import 'package:dsc26_flt_w03/data/services/api_failure.dart';
import 'package:dsc26_flt_w03/data/services/question_api.dart';
import 'package:dsc26_flt_w03/domain/models/question.dart';
import 'package:dsc26_flt_w03/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final base = Uri.parse('https://api.masaraat.test');

Map<String, Object?> q(String id) => {
  'id': id,
  'skillId': 'chem.moles',
  'stem': 'ما ناتج ٢ + ٢؟',
  'choices': ['٣', '٤', '٥'],
};

http.Response ok(
  List<Map<String, Object?>> questions, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(jsonEncode({'questions': questions})),
  200,
  headers: headers,
);

QuestionApi apiOf(
  Future<http.Response> Function(http.Request) handler, {
  Uri? baseUrl,
  Duration timeout = const Duration(seconds: 10),
}) => QuestionApi(
  client: MockClient(handler),
  baseUrl: baseUrl ?? base,
  timeout: timeout,
);

void main() {
  group('request', () {
    test('method, path, query and Accept header', () async {
      late http.Request seen;
      final api = apiOf((request) async {
        seen = request;
        return ok([q('q1')]);
      });
      final result = await api.fetchNext(studentId: 's-42', limit: 3);
      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/students/s-42/next-questions');
      expect(seen.url.queryParameters['limit'], '3');
      expect(seen.headers['Accept'], 'application/json');
      expect(
        seen.url.toString(),
        'https://api.masaraat.test/v1/students/s-42/next-questions?limit=3',
      );
      expect(result, isA<Ok<List<Question>>>());
    });

    test('preserves existing base URL path', () async {
      late Uri seen;
      final api = apiOf((request) async {
        seen = request.url;
        return ok([]);
      }, baseUrl: Uri.parse('https://api.masaraat.test/api'));
      await api.fetchNext(studentId: 's');
      expect(seen.path, '/api/v1/students/s/next-questions');
    });

    test('handles trailing slash in base URL', () async {
      late Uri seen;
      final api = apiOf((request) async {
        seen = request.url;
        return ok([]);
      }, baseUrl: Uri.parse('https://api.masaraat.test/api/'));
      await api.fetchNext(studentId: 's');
      expect(seen.path, '/api/v1/students/s/next-questions');
      expect(seen.path.contains('//'), isFalse);
    });

    test('encodes the student id as a single path segment', () async {
      late Uri seen;
      final api = apiOf((request) async {
        seen = request.url;
        return ok([]);
      });
      await api.fetchNext(studentId: 'a/b c');
      expect(seen.pathSegments, ['v1', 'students', 'a/b c', 'next-questions']);
      expect(seen.toString(), contains('students/a%2Fb%20c/next-questions'));
    });
  });

  group('validation', () {
    for (final bad in [0, -1, 51, 100]) {
      test('limit $bad throws ArgumentError without any request', () async {
        var called = false;
        final api = apiOf((_) async {
          called = true;
          return ok([]);
        });
        expect(
          () => api.fetchNext(studentId: 's', limit: bad),
          throwsArgumentError,
        );
        expect(called, isFalse);
      });
    }

    test('limit 1 and 50 are accepted', () async {
      final api = apiOf((_) async => ok([]));
      expect(
        await api.fetchNext(studentId: 's', limit: 1),
        isA<Ok<List<Question>>>(),
      );
      expect(
        await api.fetchNext(studentId: 's', limit: 50),
        isA<Ok<List<Question>>>(),
      );
    });
  });

  group('successful parsing', () {
    test('parses questions and ignores unknown fields', () async {
      final api = apiOf(
        (_) async => ok(
          [
            {
              ...q('q1'),
              'difficulty': 3,
              'extra': {'x': 1},
            },
          ],
          headers: {'content-type': 'application/json'},
        ),
      );
      final result = await api.fetchNext(studentId: 's');
      final questions = (result as Ok<List<Question>>).value;
      expect(questions.single.id, 'q1');
      expect(questions.single.skillId, 'chem.moles');
      expect(questions.single.stem, 'ما ناتج ٢ + ٢؟');
      expect(questions.single.choices, ['٣', '٤', '٥']);
    });

    test('empty questions list yields an empty Ok', () async {
      final api = apiOf((_) async => ok([]));
      final result = await api.fetchNext(studentId: 's');
      expect((result as Ok<List<Question>>).value, isEmpty);
    });

    test('Arabic UTF-8 survives a missing Content-Type', () async {
      final api = apiOf((_) async => ok([q('q1')], headers: {}));
      final result = await api.fetchNext(studentId: 's');
      expect(
        (result as Ok<List<Question>>).value.single.stem,
        'ما ناتج ٢ + ٢؟',
      );
    });

    test('Arabic UTF-8 survives a wrong Latin-1 declaration', () async {
      final api = apiOf(
        (_) async => ok(
          [q('q1')],
          headers: {'content-type': 'text/plain; charset=latin-1'},
        ),
      );
      final result = await api.fetchNext(studentId: 's');
      expect(
        (result as Ok<List<Question>>).value.single.stem,
        'ما ناتج ٢ + ٢؟',
      );
    });

    test('accepts 2 and 6 choices', () async {
      final two = q('q1')..['choices'] = ['a', 'b'];
      final six = q('q2')..['choices'] = ['1', '2', '3', '4', '5', '6'];
      final api = apiOf((_) async => ok([two, six]));
      expect((await api.fetchNext(studentId: 's') as Ok).value, hasLength(2));
    });
  });

  group('malformed responses', () {
    test('malformed JSON', () async {
      final api = apiOf(
        (_) async => http.Response.bytes(utf8.encode('{not json'), 200),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<BadResponse>(),
      );
    });

    test('invalid UTF-8 bytes', () async {
      final api = apiOf(
        (_) async => http.Response.bytes([0x7B, 0xFF, 0xFE, 0x7D], 200),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<BadResponse>(),
      );
    });

    test('top-level JSON array', () async {
      final api = apiOf(
        (_) async => http.Response.bytes(utf8.encode('[]'), 200),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<BadResponse>(),
      );
    });

    test('missing questions list', () async {
      final api = apiOf(
        (_) async => http.Response.bytes(utf8.encode('{}'), 200),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<BadResponse>(),
      );
    });

    test('questions is not a list', () async {
      final api = apiOf(
        (_) async => http.Response.bytes(utf8.encode('{"questions": 3}'), 200),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<BadResponse>(),
      );
    });

    for (final mutation in [
      () => q('q1')..remove('id'),
      () => q('q1')..['id'] = '',
      () => q('q1')..['id'] = 7,
      () => q('q1')..remove('skillId'),
      () => q('q1')..['stem'] = null,
      () => q('q1')..['stem'] = 12,
    ]) {
      test('invalid field in ${jsonEncode(mutation())}', () async {
        final api = apiOf((_) async => ok([mutation()]));
        expect(
          (await api.fetchNext(studentId: 's') as Err).failure,
          isA<BadResponse>(),
        );
      });
    }

    for (final choices in [
      <Object?>['only'],
      ['1', '2', '3', '4', '5', '6', '7'],
      ['a', ''],
      ['a', 3],
      'not a list',
    ]) {
      test('invalid choices $choices', () async {
        final api = apiOf((_) async => ok([q('q1')..['choices'] = choices]));
        expect(
          (await api.fetchNext(studentId: 's') as Err).failure,
          isA<BadResponse>(),
        );
      });
    }
  });

  group('network failures', () {
    test('timeout becomes TimedOut', () async {
      final api = apiOf((_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return ok([]);
      }, timeout: const Duration(milliseconds: 50));
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<TimedOut>(),
      );
    });

    test('ClientException becomes Offline', () async {
      final api = apiOf(
        (_) async => throw http.ClientException('no route to host'),
      );
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<Offline>(),
      );
    });

    test('unexpected socket error becomes Offline', () async {
      final api = apiOf((_) async => throw Exception('socket closed'));
      expect(
        (await api.fetchNext(studentId: 's') as Err).failure,
        isA<Offline>(),
      );
    });
  });

  group('status mapping', () {
    Future<ApiFailure> statusOf(
      int code, {
      Map<String, String> headers = const {},
    }) async {
      final api = apiOf(
        (_) async => http.Response('x', code, headers: headers),
      );
      return (await api.fetchNext(studentId: 's') as Err).failure;
    }

    test('401 and 403 become Unauthorized', () async {
      expect(await statusOf(401), isA<Unauthorized>());
      expect(await statusOf(403), isA<Unauthorized>());
    });

    test('404 becomes NotFound', () async {
      expect(await statusOf(404), isA<NotFound>());
    });

    test('429 becomes RateLimited with Retry-After', () async {
      final failure = await statusOf(429, headers: {'retry-after': '7'});
      expect(failure, isA<RateLimited>());
      expect((failure as RateLimited).retryAfter, const Duration(seconds: 7));
    });

    test('500s become ServerError', () async {
      final failure = await statusOf(503);
      expect(failure, isA<ServerError>());
      expect((failure as ServerError).statusCode, 503);
    });

    test('other statuses become UnexpectedStatus', () async {
      final failure = await statusOf(418);
      expect(failure, isA<UnexpectedStatus>());
      expect((failure as UnexpectedStatus).statusCode, 418);
    });
  });
}
