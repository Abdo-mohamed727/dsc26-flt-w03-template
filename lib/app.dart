import 'package:flutter/material.dart';

import 'data/repositories/practice_repository.dart';
import 'data/services/api_failure.dart';
import 'utils/result.dart';
import 'domain/models/question.dart';

/// The practice app. The tests only ever call this function.
///
/// Loads on start; shows loading, the list, the empty state or the failure
/// view; a refresh action in the app bar, disabled while loading.
Widget buildPracticeApp({
  required PracticeRepository repository,
  String studentId = 'demo',
}) {
  return MaterialApp(
    home: PracticeScreen(repository: repository, studentId: studentId),
  );
}

/// The controller: calls the repository and publishes immutable view states.
/// Every state update is guarded so nothing is emitted after disposal.
class PracticeController extends ChangeNotifier {
  PracticeController({
    required this._repository,
    required this.studentId,
  });

  final PracticeRepository _repository;
  final String studentId;

  PracticeState _state = const _Loading();
  bool _busy = false;
  bool _disposed = false;

  PracticeState get state => _state;
  bool get busy => _busy;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (_busy) {
      return; // No overlapping requests: a second tap is a no-op.
    }
    _busy = true;
    _state = const _Loading();
    notifyListeners();

    final result = await _repository.nextQuestions(studentId);

    _busy = false;
    if (_disposed) {
      return; // Do not notify or rebuild after disposal.
    }
    _state = switch (result) {
      final Ok<List<Question>> ok => PracticeState.loaded(ok.value),
      final Err<List<Question>> err => PracticeState.failed(err.failure),
    };
    notifyListeners();
  }
}

/// Immutable view state shown by the screen.
sealed class PracticeState {
  const PracticeState();

  factory PracticeState.loading() = _Loading;
  factory PracticeState.loaded(List<Question> questions) = _Loaded;
  factory PracticeState.failed(ApiFailure failure) = _Failed;
}

final class _Loading extends PracticeState {
  const _Loading();
}

final class _Loaded extends PracticeState {
  const _Loaded(this.questions);

  final List<Question> questions;
}

final class _Failed extends PracticeState {
  const _Failed(this.failure);

  final ApiFailure failure;
}

/// The practice screen. Owns the controller and disposes it with the widget;
/// the controller guards its own async continuations with `isClosed`.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({
    super.key,
    required this.repository,
    required this.studentId,
  });

  final PracticeRepository repository;
  final String studentId;

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  late final PracticeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PracticeController(
      repository: widget.repository,
      studentId: widget.studentId,
    );
    _controller.addListener(_onStateChanged);
    _controller.load();
  }

  void _onStateChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onStateChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Friendly, non-technical messages; nothing leaks exception details.
  String _messageFor(ApiFailure failure) => switch (failure) {
    Unauthorized() => 'You need to sign in to continue.',
    Offline() => 'You appear to be offline. Check your connection.',
    TimedOut() => 'The server took too long to answer.',
    RateLimited() => 'You are practicing too quickly. Try again soon.',
    ServerError() => 'The server is having trouble. Try again later.',
    NotFound() => 'No practice was found for this student.',
    BadResponse() => 'The server sent an unexpected answer.',
    UnexpectedStatus() => 'Something unexpected happened. Try again.',
  };

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final busy = _controller.busy;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المسارات — تدريب اليوم'),
          actions: [
            IconButton(
              key: const Key('practice-refresh'),
              onPressed: busy ? null : _controller.load,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        body: switch (state) {
          _Loading() => const Center(
            key: Key('practice-loading'),
            child: CircularProgressIndicator(),
          ),
          _Loaded(:final questions) =>
            questions.isEmpty
                ? const Center(
                    key: Key('practice-empty'),
                    child: Text("you have finished today's practice"),
                  )
                : ListView.builder(
                    key: const Key('practice-list'),
                    itemCount: questions.length,
                    itemBuilder: (context, index) {
                      final question = questions[index];
                      return Card(
                        key: Key('question-${question.id}'),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                question.stem,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(height: 1.6),
                              ),
                              const SizedBox(height: 12),
                              ...question.choices.map(
                                (choice) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.radio_button_unchecked,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(choice)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          _Failed(:final failure) => Center(
            key: const Key('practice-error'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    failure is Unauthorized
                        ? Icons.lock_outline
                        : Icons.cloud_off,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(_messageFor(failure), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  failure is Unauthorized
                      ? ElevatedButton.icon(
                          key: const Key('practice-signin'),
                          // No auth flow exists in this project yet, so the
                          // button is a placeholder for the sign-in action.
                          onPressed: () {},
                          icon: const Icon(Icons.login),
                          label: const Text('تسجيل الدخول'),
                        )
                      : ElevatedButton.icon(
                          key: const Key('practice-retry'),
                          onPressed: _controller.load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('إعادة المحاولة'),
                        ),
                ],
              ),
            ),
          ),
        },
      ),
    );
  }
}
