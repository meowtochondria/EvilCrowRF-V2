import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_colors.dart';

class FilePreviewWidget extends StatelessWidget {
  final String fileName;
  final String content;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback? onRetry;

  const FilePreviewWidget({
    super.key,
    required this.fileName,
    required this.content,
    this.isLoading = false,
    this.errorMessage,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context)!.loadingFilePreview),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
              color: AppColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.previewError,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.error,
                  ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                errorMessage!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.greyLight,
                    ),
                textAlign: TextAlign.center,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                child: Text(AppLocalizations.of(context)!.retry),
              ),
            ],
          ],
        ),
      );
    }

    final extension = _getFileExtension();
    final previewContent = _getPreviewContent(content, extension);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.secondaryBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.greyLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _getFileIcon(extension),
                size: 20,
                color: _getFileIconColor(extension),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                AppLocalizations.of(context)!.chars(content.length),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.greyDark,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.onButton,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.greyLight),
              ),
              child: SingleChildScrollView(
                child: Text(
                  previewContent,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
          if (content.length > 500) ...[
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.previewTruncated,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.greyDark,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  String _getFileExtension() {
    final lastDot = fileName.lastIndexOf('.');
    return lastDot != -1 ? fileName.substring(lastDot + 1).toLowerCase() : '';
  }

  IconData _getFileIcon(String extension) {
    switch (extension) {
      case 'txt':
      case 'log':
        return Icons.description;
      case 'json':
        return Icons.code;
      case 'sub':
        return Icons.radio;
      case 'bin':
      case 'hex':
        return Icons.memory;
      case 'wav':
      case 'mp3':
        return Icons.audiotrack;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'zip':
      case 'rar':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileIconColor(String extension) {
    switch (extension) {
      case 'txt':
      case 'log':
        return AppColors.statusBlue;
      case 'json':
        return AppColors.statusOrange;
      case 'sub':
        return AppColors.statusPurple;
      case 'bin':
      case 'hex':
        return AppColors.error;
      case 'wav':
      case 'mp3':
        return AppColors.success;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return AppColors.statusTeal;
      case 'zip':
      case 'rar':
        return AppColors.statusBrown;
      default:
        return AppColors.greyLight;
    }
  }

  String _getPreviewContent(String content, String extension) {
    // Limit preview length
    const maxPreviewLength = 500;

    if (content.length <= maxPreviewLength) {
      return content;
    }

    String preview = content.substring(0, maxPreviewLength);

    // For JSON try to find end of object/array
    if (extension == 'json') {
      try {
        int braceCount = 0;
        int bracketCount = 0;
        int lastValidPos = 0;

        for (int i = 0; i < preview.length; i++) {
          switch (preview[i]) {
            case '{':
              braceCount++;
              break;
            case '}':
              braceCount--;
              if (braceCount == 0 && bracketCount == 0) {
                lastValidPos = i + 1;
              }
              break;
            case '[':
              bracketCount++;
              break;
            case ']':
              bracketCount--;
              if (braceCount == 0 && bracketCount == 0) {
                lastValidPos = i + 1;
              }
              break;
          }
        }

        if (lastValidPos > 100) {
          preview = preview.substring(0, lastValidPos);
        }
      } catch (e) {
        // If something went wrong, use regular truncation
      }
    }

    return '$preview...';
  }
}
