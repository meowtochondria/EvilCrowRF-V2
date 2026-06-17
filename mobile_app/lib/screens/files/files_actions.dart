import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/files_provider.dart';
import '../../providers/log_provider.dart';
import '../../services/logger_service.dart';
import '../../theme/app_colors.dart';

/// Standalone file action handlers for the Files screen.
///
/// Extracted from `files_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`. The dialogs and upload flow lived at the bottom of
/// the screen file; they are extracted here so the screen file can stay
/// focused on layout / state, and the action flows can be unit-tested
/// without spinning up a full `StatefulWidget`.
///
/// Each function takes the explicit dependencies it needs (BuildContext for
/// navigation, FilesProvider for I/O, LogProvider for diagnostics). Snackbar
/// feedback is handled via the supplied callbacks so callers can choose
/// their own presentation.
class FilesActions {
  /// Show the "Create Directory" dialog and create the new directory on
  /// the device. Returns when the operation completes.
  static Future<void> showCreateDirectoryDialog(
    BuildContext context,
    FilesProvider filesProvider, {
    required void Function(String message) onSuccess,
    required void Function(String message) onError,
  }) async {
    final nameController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return AlertDialog(
          title: Text(
            l10n.createDirectory,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: TextField(
            controller: nameController,
            decoration: InputDecoration(
              labelText: l10n.directoryName,
              border: const OutlineInputBorder(),
              hintText: l10n.enterDirectoryName,
            ),
            autofocus: true,
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                Navigator.of(dialogContext).pop(value.trim());
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isNotEmpty) {
                  Navigator.of(dialogContext).pop(name);
                }
              },
              child: Text(l10n.create),
            ),
          ],
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      try {
        // Build full path for directory creation
        String fullPath;
        if (filesProvider.currentPath == '/' ||
            filesProvider.currentPath.isEmpty) {
          fullPath = result;
        } else {
          fullPath = '${filesProvider.currentPath}/$result';
        }

        await filesProvider.createDirectory(fullPath);

        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          onSuccess(l10n.directoryCreated(result));
          // Refresh file list
          await filesProvider.refreshFileList(forceRefresh: true);
        }
      } catch (e) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          onError(l10n.failedToCreateDirectory(e.toString()));
        }
      }
    }
  }

  /// Show the native file picker, then upload the selected file to the
  /// device's current directory. Shows a progress dialog while uploading.
  static Future<void> uploadFileFromDevice(
    BuildContext context,
    FilesProvider filesProvider, {
    required void Function(String message) onSuccess,
    required void Function(String message) onError,
  }) async {
    try {
      // Select file from device
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;
        final file = File(filePath);

        if (!await file.exists()) {
          if (context.mounted) {
            final l10n = AppLocalizations.of(context)!;
            onError(l10n.selectedFileDoesNotExist);
          }
          return;
        }

        if (context.mounted) {
          // Show progress dialog
          final l10n = AppLocalizations.of(context)!;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.uploadingFile(fileName)),
                ],
              ),
            ),
          );
        }

        try {
          // Use current directory and pathType
          final currentPath = filesProvider.currentPath;
          final pathType = filesProvider.currentPathType;

          AppLogger.debug(
              'Upload: currentPath="$currentPath", pathType=$pathType, fileName="$fileName"');

          // Build full path for upload
          String targetPath = fileName;
          if (currentPath != '/' && currentPath.isNotEmpty) {
            // Remove leading slash if present
            String cleanPath = currentPath.startsWith('/')
                ? currentPath.substring(1)
                : currentPath;
            targetPath = '$cleanPath/$fileName';
          }

          AppLogger.debug('Upload: targetPath="$targetPath"');

          // Upload file
          final response = await filesProvider.uploadFile(
            file,
            targetPath,
            pathType: pathType,
            onProgress: (progress) {
              // Could update progress in dialog, but keeping it simple for now
            },
          );

          if (context.mounted) {
            Navigator.of(context).pop(); // Close progress dialog
            final l10n = AppLocalizations.of(context)!;

            if (response['success'] == true) {
              onSuccess(l10n.fileUploaded(fileName));
              // Refresh file list
              await filesProvider.refreshFileList(forceRefresh: true);
            } else {
              final errorMsg =
                  response['error'] ?? l10n.uploadFailed('Unknown error');
              onError(l10n.uploadFailed(errorMsg));
            }
          }
        } catch (e) {
          if (context.mounted) {
            Navigator.of(context).pop(); // Close progress dialog
            final l10n = AppLocalizations.of(context)!;

            final errorMessage = l10n.uploadFailed(e.toString());

            // Log to LogProvider for display on debug screen
            final logProvider =
                Provider.of<LogProvider>(context, listen: false);
            logProvider.addErrorLog(errorMessage, details: 'File: $fileName');

            // Show dialog with full error message
            if (context.mounted) {
              showDialog(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.error),
                      const SizedBox(width: 8),
                      Text(l10n.uploadError),
                    ],
                  ),
                  content: Text(errorMessage),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(l10n.ok),
                    ),
                  ],
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        onError(l10n.failedToPickFile(e.toString()));
      }
    }
  }
}
