import '../../domain/models/question.dart';
import '../../utils/result.dart';
import '../services/api_failure.dart';
import '../services/question_api.dart';

/// The source of truth for practice questions. Owns the retry policy.
///
/// Keep the constructor and the signature of [nextQuestions] exactly.
class PracticeRepository {
  PracticeRepository({
    required this._api,
    required this._sleep,
    this._maxRetries = 2,
  });

  static const _maxRetryAfter = Duration(seconds: 30);

  final QuestionApi _api;
  final Future<void> Function(Duration) _sleep;
  final int _maxRetries;

  /// Retry transient failures at most [_maxRetries] times, waiting
  /// 1 s, 2 s, ... (`Retry-After` for 429, capped at 30 s). Return permanent
  /// failures after one call.
  Future<Result<List<Question>>> nextQuestions(String studentId) async {
    var attempt = 0;
    while (true) {
      final result = await _api.fetchNext(studentId: studentId);
      final failure = switch (result) {
        Ok<List<Question>>() => null,
        final Err<List<Question>> err => err.failure,
      };

      if (failure == null || !failure.isTransient || attempt >= _maxRetries) {
        return result;
      }

      // The delay always comes from the failure of the call just made.
      final delay = switch (failure) {
        final RateLimited limited =>
          limited.retryAfter > _maxRetryAfter
              ? _maxRetryAfter
              : limited.retryAfter,
        _ => Duration(seconds: 1 << attempt),
      };

      await _sleep(delay);
      attempt++;
    }
  }
}
