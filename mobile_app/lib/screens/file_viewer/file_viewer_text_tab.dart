import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';

/// "Text" tab of [FileViewerScreen] — shows the raw file content as plain
/// selectable text. Handles the three states the parent passes in:
///   - loading / no content (shows a placeholder)
///   - error (with a retry button)
///   - ready (renders the text in a monospace scroll view)
///
/// Extracted from `file_viewer_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
class FileViewerTextTab extends StatelessWidget {
  final String? fileContent;
  final String? errorMessage;
  final VoidCallback onRetry;

  const FileViewerTextTab({
    super.key,
    required this.fileContent,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (fileContent == null) {
      if (errorMessage != null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: AppColors.secondaryText),
              const SizedBox(height: 16),
              Text(errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(AppLocalizations.of(context)!.reload),
              ),
            ],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.description_outlined,
                size: 48, color: AppColors.secondaryText),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context)!.noContentAvailable),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context)!.reload),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        fileContent!,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
        ),
      ),
    );
  }
}
