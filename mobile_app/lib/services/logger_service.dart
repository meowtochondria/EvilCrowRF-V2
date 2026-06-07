import 'package:logging/logging.dart' as logging;
import '../providers/log_provider.dart';

/// Centralized application logger.
///
/// Uses the `logging` package for structured, leveled logging to the
/// developer console, and also feeds logs into the in-app [LogProvider]
/// for display in the debug screen.
///
/// Usage:
/// ```dart
/// import 'logger_service.dart';
/// AppLogger.info('BLE connected');
/// AppLogger.warning('Low signal strength', details: '-80 dBm');
/// AppLogger.severe('Connection lost', error, stackTrace);
/// ```
class AppLogger {
  static logging.Logger? _logger;
  static LogProvider? _logProvider;

  /// Initialize the logger. Call this once from main().
  ///
  /// If [appName] is null, it will be resolved from [PackageInfo] synchronously.
  /// In practice, pass the value from [PackageInfo.fromPlatform] in main().
  static void init({LogProvider? logProvider, String? appName}) {
    _logProvider = logProvider;

    // Resolve app name — passed in from main() via PackageInfo, or fallback
    final name = appName ?? 'evilcrow_rf2_controller';
    _logger = logging.Logger(name);

    // Log all messages at FINEST and above to the console
    logging.hierarchicalLoggingEnabled = true;
    _logger!.level = logging.Level.ALL;

    // Print to console with timestamp, level, and message
    _logger!.onRecord.listen((record) {
      // ignore: avoid_print
      print(
        '[${record.time.hour.toString().padLeft(2, '0')}:'
        '${record.time.minute.toString().padLeft(2, '0')}:'
        '${record.time.second.toString().padLeft(2, '0')}.'
        '${record.time.millisecond.toString().padLeft(3, '0')}] '
        '${record.level.name}: '
        '${record.message}'
        '${record.error != null ? '\n  Error: ${record.error}' : ''}'
        '${record.stackTrace != null ? '\n  Stack: ${record.stackTrace}' : ''}',
      );
    });
  }

  /// Detailed debug-level information (fine-grained).
  static void debug(String message, [Object? error, StackTrace? stackTrace]) {
    _logger?.finest(message, error, stackTrace);
  }

  /// General informational messages.
  static void info(String message) {
    _logger?.info(message);
    _logProvider?.addInfoLog(message);
  }

  /// Warning messages for potentially harmful situations.
  static void warning(String message, {String? details}) {
    _logger?.warning(message);
    _logProvider
        ?.addWarningLog(details != null ? '$message: $details' : message);
  }

  /// Error / severe messages indicating failures.
  static void severe(String message, [Object? error, StackTrace? stackTrace]) {
    _logger?.severe(message, error, stackTrace);
    _logProvider?.addErrorLog(message, details: error?.toString());
  }

  /// Command messages (BLE commands sent to device).
  static void command(String message) {
    _logger?.info('CMD: $message');
    _logProvider?.addCommandLog(message);
  }

  /// Response messages (data received from device).
  static void response(String message) {
    _logger?.info('RESP: $message');
    _logProvider?.addResponseLog(message);
  }
}
