
/// Lightweight, type-safe event bus for cross-provider communication.
///
/// Layer 2 of the two-layer routing model (Layer 1 is [MessageDispatcher]).
///
/// Module providers emit domain events when their state changes in ways that
/// other providers need to react to. This replaces the old pattern of screens
/// directly mutating [BleProvider] fields.
///
/// Currently needed event types:
///   1. [SubGhzStartedRecording] / [SubGhzStoppedRecording]
///   2. [NrfModuleStateChanged]
///   3. [ConnectionLost]
///
/// Usage:
/// ```dart
/// // Emitter
/// AppEventBus().emit(SubGhzStartedRecording(moduleIndex: 0));
///
/// // Subscriber
/// AppEventBus().on<SubGhzStartedRecording>(_onRecordingStarted);
/// // ... dispose
/// AppEventBus().off<SubGhzStartedRecording>(_onRecordingStarted);
/// ```
class AppEventBus {
  static final AppEventBus _instance = AppEventBus._internal();
  factory AppEventBus() => _instance;
  AppEventBus._internal();

  final _controllers = <Type, dynamic>{};

  /// Emit a typed event to all subscribers.
  void emit<T>(T event) {
    if (_controllers.containsKey(T)) {
      (_controllers[T]! as _EventController<T>).add(event);
    }
  }

  /// Subscribe to a typed event.
  void on<T>(void Function(T) callback) {
    if (!_controllers.containsKey(T)) {
      _controllers[T] = _EventController<T>();
    }
    (_controllers[T]! as _EventController<T>).subscribe(callback);
  }

  /// Unsubscribe from a typed event.
  void off<T>(void Function(T) callback) {
    if (_controllers.containsKey(T)) {
      (_controllers[T]! as _EventController<T>).unsubscribe(callback);
    }
  }
}

class _EventController<T> {
  final List<void Function(T)> _listeners = [];
  void add(T event) => _listeners.toList().forEach((l) => l(event));
  void subscribe(void Function(T) callback) => _listeners.add(callback);
  void unsubscribe(void Function(T) callback) => _listeners.remove(callback);
}

// ════════════════════════════════════════════════════════════════════
//  Event type definitions
// ════════════════════════════════════════════════════════════════════

/// Emitted when a CC1101 module starts recording a signal.
class SubGhzStartedRecording {
  final int moduleIndex;
  SubGhzStartedRecording({required this.moduleIndex});
}

/// Emitted when a CC1101 module stops recording.
class SubGhzStoppedRecording {
  final int moduleIndex;
  SubGhzStoppedRecording({required this.moduleIndex});
}

/// Emitted when the NRF24 module state changes (e.g. busy/available).
class NrfModuleStateChanged {
  final bool busy;
  final String? reason;
  NrfModuleStateChanged({required this.busy, this.reason});
}

/// Emitted when the connection to the device is lost, so providers can clean up.
class ConnectionLost {
  final String reason;
  ConnectionLost(this.reason);
}
