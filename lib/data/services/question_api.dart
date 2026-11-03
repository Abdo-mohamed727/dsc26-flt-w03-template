import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/question.dart';
import '../../utils/result.dart';
import 'api_failure.dart';

/// One call to the Masaraat questions API. Holds no state and never retries.
///
/// Keep the constructor and the signature of [fetchNext] exactly.
class QuestionApi {
  QuestionApi({
    required this._client,
    required this._baseUrl,
    this._timeout = const Duration(seconds: 10),
  });

  final http.Client _client;
  final Uri _baseUrl;
  final Duration _timeout;

  /// `GET {baseUrl}/v1/students/{studentId}/next-questions?limit={limit}`.
  ///
  /// TODO(W3): see the README for the URL, headers, parsing, status mapping
  /// and network failures. Never throws for network or server problems.
  Future<Result<List<Question>>> fetchNext({
    required String studentId,
    int limit = 10,
  }) async {
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 50');
    }

    // Preserve any path already present in the base URL, ignoring trailing
    // slashes, then append the fixed endpoint segments.
    final existingSegments = _baseUrl.pathSegments.toList()
      ..removeWhere((segment) => segment.isEmpty);

    final url = _baseUrl.replace(
      pathSegments: [
        ...existingSegments,
        'v1',
        'students',
        studentId,
        'next-questions',
      ],
      queryParameters: {'limit': '$limit'},
    );

    final http.Response response;
    try {
      response = await _client
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(_timeout);
    } on TimeoutException {
      return const Err(TimedOut());
    } on http.ClientException {
      return const Err(Offline());
    } catch (_) {
      return const Err(Offline());
    }

    return _mapStatus(response);
  }

  Result<List<Question>> _mapStatus(http.Response response) {
    final status = response.statusCode;
    switch (status) {
      case 200:
        return _parse(response);
      case 401:
      case 403:
        return const Err(Unauthorized());
      case 404:
        return const Err(NotFound());
      case 429:
        return Err(RateLimited(_retryAfter(response)));
      default:
        if (status >= 500 && status <= 599) {
          return Err(ServerError(status));
        }
        return Err(UnexpectedStatus(status));
    }
  }

  /// Reads whole seconds from the `Retry-After` header; 0 when absent or
  /// unparsable.
  Duration _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    final seconds = int.tryParse(raw ?? '');
    return Duration(seconds: seconds ?? 0);
  }

  Result<List<Question>> _parse(http.Response response) {
    try {
      // Decode explicitly as UTF-8: the backend may omit Content-Type or
      // wrongly declare Latin-1, and Arabic text must survive intact.
      final body = utf8.decode(response.bodyBytes);
      final decoded = jsonDecode(body);

      if (decoded is! Map<String, Object?>) {
        return const Err(BadResponse('top-level JSON is not an object'));
      }
      final questions = decoded['questions'];
      if (questions is! List) {
        return const Err(BadResponse('missing or invalid "questions" list'));
      }

      final parsed = <Question>[];
      for (final entry in questions) {
        if (entry is! Map<String, Object?>) {
          return const Err(BadResponse('question is not an object'));
        }
        final id = entry['id'];
        final skillId = entry['skillId'];
        final stem = entry['stem'];
        final choices = entry['choices'];
        if (id is! String || id.isEmpty) {
          return const Err(BadResponse('question id'));
        }
        if (skillId is! String || skillId.isEmpty) {
          return const Err(BadResponse('question skillId'));
        }
        if (stem is! String || stem.isEmpty) {
          return const Err(BadResponse('question stem'));
        }
        if (choices is! List ||
            choices.length < 2 ||
            choices.length > 6 ||
            choices.any((choice) => choice is! String || choice.isEmpty)) {
          return const Err(BadResponse('question choices'));
        }
        parsed.add(
          Question(
            id: id,
            skillId: skillId,
            stem: stem,
            choices: List<String>.unmodifiable(choices.cast<String>()),
          ),
        );
      }
      return Ok(parsed);
    } on FormatException catch (e) {
      return Err(BadResponse('malformed JSON (${e.message})'));
    } catch (_) {
      return const Err(BadResponse('unreadable response body'));
    }
  }
}
