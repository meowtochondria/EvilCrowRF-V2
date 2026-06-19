import 'dart:async';
import '../connection/message_dispatcher.dart';

/// Tracks pending requests with timeouts for response correlation.
///
/// When a provider sends a command with a requestId (chunkId), it registers
/// the expected response type(s). If no matching response arrives within the
/// timeout, [onTimeout] fires so the provider can update its UI state.
///
/// Usage:
/// ```dart
/// final tracker = PendingRequestTracker(dispatcher);
/// tracker.track(expectedType: 'VersionInfo', onTimeout: () => showError());
/// // Response arrives via dispatcher → tracker auto-cancels
/// ```
class PendingRequestTracker {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final Set<String> _waitingFor = {};
  final Map<String, Timer> _timers = {};
  final Map<String, void Function()> _timeoutCallbacks = {};

  PendingRequestTracker(MessageDispatcher dispatcher) {
    _subscription = dispatcher.messages.listen(_onMessage);
  }

  /// Track a pending request expecting [expectedType] response.
  /// If no matching response arrives in [timeout], [onTimeout] is called.
  void track({
    required String expectedType,
    Duration timeout = const Duration(seconds: 15),
    required void Function() onTimeout,
  }) {
    _waitingFor.add(expectedType);
    _timeoutCallbacks[expectedType] = onTimeout;
    _timers[expectedType] = Timer(timeout, () {
      if (_waitingFor.contains(expectedType)) {
        _waitingFor.remove(expectedType);
        _timeoutCallbacks.remove(expectedType)?.call();
      }
    });
  }

  /// Cancel tracking for a specific response type.
  void cancel(String expectedType) {
    _waitingFor.remove(expectedType);
    _timers.remove(expectedType)?.cancel();
    _timeoutCallbacks.remove(expectedType);
  }

  void _onMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    if (type != null && _waitingFor.contains(type)) {
      _timers[type]?.cancel();
      _waitingFor.remove(type);
      _timeoutCallbacks.remove(type);
    }
  }

  /// Cancel all pending requests.
  void clear() {
    for (final t in _timers.values) t.cancel();
    _waitingFor.clear();
    _timers.clear();
    _timeoutCallbacks.clear();
  }

  void dispose() {
    clear();
    _subscription?.cancel();
  }
}
