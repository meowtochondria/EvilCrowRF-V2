import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

enum LogLevel {
  info,
  warning,
  error,
  command,
  response,
}

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? details;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.details,
  });

  String get formattedTime {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  Color get levelColor {
    switch (level) {
      case LogLevel.info:
        return AppColors.statusBlue;
      case LogLevel.warning:
        return AppColors.statusOrange;
      case LogLevel.error:
        return AppColors.error;
      case LogLevel.command:
        return AppColors.success;
      case LogLevel.response:
        return AppColors.statusPurple;
    }
  }

  IconData get levelIcon {
    switch (level) {
      case LogLevel.info:
        return Icons.info;
      case LogLevel.warning:
        return Icons.warning;
      case LogLevel.error:
        return Icons.error;
      case LogLevel.command:
        return Icons.send;
      case LogLevel.response:
        return Icons.reply;
    }
  }

  String get levelName {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
      case LogLevel.command:
        return 'CMD';
      case LogLevel.response:
        return 'RESP';
    }
  }
}
