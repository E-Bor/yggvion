import 'dart:async';
import 'dart:isolate';
import '../domain/fuzzy_search.dart';

/// Keeps the vocabulary and its prefix tree off the UI isolate between queries.
class SearchWorker {
  Isolate? _isolate;
  ReceivePort? _events;
  Completer<SendPort>? _ready;
  final _requests = <int, Completer<List<String>>>{};
  int _nextId = 0;
  bool _disposed = false;
  Object? _failure;

  Future<SendPort> _start() {
    if (_disposed) return Future.error(StateError('Search worker is closed'));
    if (_failure != null) return Future.error(_failure!);
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<SendPort>();
    final events = _events = ReceivePort();
    events.listen((message) {
      switch (message) {
        case SendPort port:
          if (!ready.isCompleted) ready.complete(port);
        case (int id, List<String> queries, null):
          _requests.remove(id)?.complete(queries);
        case (int id, null, String error):
          _requests.remove(id)?.completeError(StateError(error));
        default:
          _fail(StateError('Search worker stopped: $message'));
      }
    });
    Isolate.spawn(
      _serve,
      events.sendPort,
      debugName: 'search-prefixes',
      onExit: events.sendPort,
      onError: events.sendPort,
    ).then((isolate) {
      if (_disposed || !identical(_ready, ready)) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }, onError: (Object error, StackTrace stack) => _fail(error, stack));
    return ready.future;
  }

  Future<List<String>> expand(
    List<String> words,
    int tolerance, {
    List<String>? vocabulary,
  }) async {
    // A retry must supply a fresh vocabulary after a worker failure.
    if (vocabulary != null && _failure != null && !_disposed) {
      _ready = null;
      _failure = null;
    }
    final port = await _start();
    if (_disposed) throw StateError('Search worker is closed');
    final id = ++_nextId;
    final response = Completer<List<String>>();
    _requests[id] = response;
    port.send((id, words, tolerance, vocabulary));
    return response.future;
  }

  void _fail(Object error, [StackTrace? stack]) {
    _failure = error;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error, stack);
    for (final request in _requests.values) {
      request.completeError(error, stack);
    }
    _requests.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _events?.close();
    _isolate = null;
    _events = null;
    // Keep the failure until the caller explicitly reloads the vocabulary.
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fail(StateError('Search worker is closed'));
  }

  static void _serve(SendPort output) {
    final input = ReceivePort();
    FuzzyVocabulary? vocabulary;
    output.send(input.sendPort);
    input.listen((dynamic message) {
      final (int id, List<String> words, int tolerance, List<String>? terms) =
          message;
      try {
        if (terms != null) vocabulary = FuzzyVocabulary(terms);
        if (vocabulary == null) {
          throw StateError('Search vocabulary is not loaded');
        }
        output.send((id, vocabulary!.expand(words, tolerance), null));
      } catch (error) {
        output.send((id, null, error.toString()));
      }
    });
  }
}
