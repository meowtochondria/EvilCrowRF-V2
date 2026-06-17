import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/subghz_provider.dart';
import '../../services/logger_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/file_list_widget.dart';
import '../file_viewer_screen.dart';

/// File list shown below the recording config panel. Lists all .sub files
/// captured by the given CC1101 module during this session, plus the option
/// to transmit / save / delete each file.
///
/// Extracted from `record_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
class RecordFileList extends StatelessWidget {
  final int moduleIndex;
  final void Function(dynamic file, String action) onFileAction;
  final void Function(dynamic file) onOpenFile;

  const RecordFileList({
    super.key,
    required this.moduleIndex,
    required this.onFileAction,
    required this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        // Update local list when recordedRuntimeFiles changes
        final runtimeFiles = subGhz.recordedRuntimeFiles;
        AppLogger.debug(
            'RecordFileList: Module $moduleIndex, runtimeFiles count: ${runtimeFiles.length}');

        // Filter files by module
        final moduleFiles = <dynamic>[];

        for (final file in runtimeFiles) {
          // Extract filename from object
          String fileName;
          DateTime? dateCreated;

          if (file.containsKey('filename')) {
            fileName = file['filename'].toString();
          } else {
            fileName = file.toString();
          }

          // Extract creation date if present
          if (file.containsKey('date')) {
            try {
              if (file['date'] is String) {
                dateCreated = DateTime.tryParse(file['date']);
              }
            } catch (e) {
              AppLogger.debug('Error parsing date for file $fileName', e);
            }
          }

          // Check if file belongs to this module
          if (_isFileFromModule(fileName, moduleIndex)) {
            final fileObject =
                _createFileObject(fileName, dateCreated: dateCreated);
            if (!moduleFiles.any((f) => f.name == fileName)) {
              moduleFiles.add(fileObject);
            }
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header styled like settings form
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Text(
                AppLocalizations.of(context)!
                    .signalsCaptured(moduleIndex + 1, moduleFiles.length),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryText,
                    ),
              ),
            ),
            // File list without header
            SizedBox(
              height: 200,
              child: FileListWidget(
                files: moduleFiles,
                mode: FileListMode.local,
                title: AppLocalizations.of(context)!
                    .signalsCaptured(moduleIndex + 1, moduleFiles.length),
                showHeader: false,
                showActions: true,
                filterExtension: 'sub',
                onRefresh: null, // Disable pull-to-refresh
                onFileSelected: onOpenFile,
                onFileAction: onFileAction,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Determines if a file belongs to the specified module by filename
  /// Filename format: m{module}_{frequency}_{modulation}_{bandwidth}_{random}.sub
  static bool _isFileFromModule(String fileName, int moduleIndex) {
    final regex = RegExp(r'^m(\d+)_');
    final match = regex.firstMatch(fileName);
    if (match != null) {
      final fileModule = int.tryParse(match.group(1) ?? '');
      return fileModule == moduleIndex;
    }
    return false;
  }

  static dynamic _createFileObject(String fileName, {DateTime? dateCreated}) {
    return _FileObject(
      name: fileName,
      size: 0, // Size will be updated when file info is received
      isDirectory: false,
      isFile: true,
      dateCreated: dateCreated,
    );
  }
}

/// Open the standard file viewer for a recorded signal file.
void openRecordedFileViewer(BuildContext context, dynamic file) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (context) => FileViewerScreen(
        fileItem: file,
        filePath: file.name,
        pathType: 1, // SIGNALS
      ),
    ),
  );
}

/// Simple class for representing a file in the local list.
class _FileObject {
  final String name;
  final int size;
  final bool isDirectory;
  final bool isFile;
  final DateTime? dateCreated;

  _FileObject({
    required this.name,
    required this.size,
    required this.isDirectory,
    required this.isFile,
    this.dateCreated,
  });
}
