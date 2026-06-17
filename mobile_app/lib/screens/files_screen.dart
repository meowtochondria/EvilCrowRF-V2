import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import '../providers/files_provider.dart';
import '../providers/connection_state_provider.dart';
import '../providers/notification_provider.dart';
import '../widgets/file_list_widget.dart';
import '../widgets/directory_picker_dialog.dart';
import '../widgets/transmit_file_dialog.dart';
import '../theme/app_colors.dart';
import 'file_viewer_screen.dart';
import '../services/logger_service.dart';
import 'files/files_actions.dart';

class FilesScreen extends StatefulWidget {
  final bool pickMode;
  final Set<String>? allowedExtensions;

  const FilesScreen({
    super.key,
    this.pickMode = false,
    this.allowedExtensions,
  });

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  bool _isMultiSelectMode = false;
  final Set<String> _selectedFiles = <String>{};

  @override
  void initState() {
    super.initState();
    // Load file list on initialization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final files = context.read<FilesProvider>();
      if (context.read<ConnectionStateProvider>().isConnected) {
        files.refreshFileList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FilesProvider>(
      builder: (context, filesProvider, child) {
        if (!context.read<ConnectionStateProvider>().isConnected) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.bluetooth_disabled,
                      size: 64,
                      color: AppColors.secondaryText,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppLocalizations.of(context)!.notConnectedToDevice,
                      style: const TextStyle(
                        fontSize: 18,
                        color: AppColors.secondaryText,
                      ),
                    ),
                    Text(
                      AppLocalizations.of(context)!
                          .connectToDeviceToManageFiles,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // Intercept Android back button: navigate up when inside a
        // subdirectory instead of popping the entire screen.
        final bool isInSubdir = filesProvider.currentPath != '/' &&
            filesProvider.currentPath.isNotEmpty;

        return PopScope(
          canPop: !isInSubdir,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              filesProvider.navigateUp();
            }
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  // ── Storage toggle: SD Card / Internal (LittleFS) ──
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: AppColors.primaryBackground,
                    child: Row(
                      children: [
                        const Icon(Icons.storage,
                            size: 16, color: AppColors.secondaryText),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SegmentedButton<bool>(
                            segments: [
                              ButtonSegment<bool>(
                                value: false,
                                label: Text(
                                    AppLocalizations.of(context)!.sdCard,
                                    style: const TextStyle(fontSize: 11)),
                                icon: const Icon(Icons.sd_card, size: 14),
                              ),
                              ButtonSegment<bool>(
                                value: true,
                                label: Text(
                                    AppLocalizations.of(context)!.internal,
                                    style: const TextStyle(fontSize: 11)),
                                icon: const Icon(Icons.memory, size: 14),
                              ),
                            ],
                            selected: {filesProvider.currentPathType == 4},
                            onSelectionChanged: (selected) {
                              if (selected.first) {
                                filesProvider.switchPathType(4); // LittleFS
                              } else {
                                filesProvider.switchPathType(5); // SD Root
                              }
                            },
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: WidgetStateProperty.all(
                                const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Compact header with path and dropdown
                  Container(
                    height: 48, // Compact height
                    color: AppColors.secondaryBackground,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8.0, vertical: 4.0),
                    child: Row(
                      children: [
                        // Show back button only when not in root directory
                        if (filesProvider.currentPath != '/' &&
                            filesProvider.currentPath.isNotEmpty)
                          IconButton(
                            onPressed: () => filesProvider.navigateUp(),
                            icon: const Icon(Icons.arrow_back),
                            iconSize: 20,
                          ),
                        Expanded(
                          child: _buildPathWithDropdown(context, filesProvider),
                        ),
                      ],
                    ),
                  ),
                  // Button panel
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8.0, vertical: 4.0),
                    color: Theme.of(context).colorScheme.surface,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (filesProvider.isLoadingFiles)
                          IconButton(
                            onPressed: () =>
                                filesProvider.resetFileLoadingState(),
                            icon: const Icon(Icons.stop),
                            iconSize: 20,
                            tooltip: AppLocalizations.of(context)!.stopLoading,
                            color: AppColors.error,
                          )
                        else
                          IconButton(
                            onPressed: () => filesProvider.refreshFileList(
                                forceRefresh: true),
                            icon: const Icon(Icons.refresh),
                            iconSize: 20,
                            tooltip: AppLocalizations.of(context)!.refresh,
                          ),
                        IconButton(
                          onPressed: () =>
                              FilesActions.showCreateDirectoryDialog(
                            context,
                            filesProvider,
                            onSuccess: _showSuccessSnackBar,
                            onError: _showErrorSnackBar,
                          ),
                          icon: const Icon(Icons.create_new_folder),
                          iconSize: 20,
                          tooltip:
                              AppLocalizations.of(context)!.createDirectory,
                        ),
                        IconButton(
                          onPressed: () => FilesActions.uploadFileFromDevice(
                            context,
                            filesProvider,
                            onSuccess: _showSuccessSnackBar,
                            onError: _showErrorSnackBar,
                          ),
                          icon: const Icon(Icons.upload_file),
                          iconSize: 20,
                          tooltip: AppLocalizations.of(context)!.uploadFile,
                        ),
                        IconButton(
                          onPressed: () => _toggleMultiSelectMode(),
                          icon: Icon(_isMultiSelectMode
                              ? Icons.checklist
                              : Icons.checklist_outlined),
                          iconSize: 20,
                          tooltip: _isMultiSelectMode
                              ? AppLocalizations.of(context)!.exitMultiSelect
                              : AppLocalizations.of(context)!.multiSelect,
                        ),
                      ],
                    ),
                  ),
                  // File count bar
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12.0, vertical: 4.0),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withOpacity(0.3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _buildFileCountText(filesProvider),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  // File list
                  Expanded(
                    child: FileListWidget(
                      files: filesProvider.fileList,
                      mode: _isMultiSelectMode
                          ? FileListMode.multiSelect
                          : FileListMode.browse,
                      currentPath: filesProvider.currentPath,
                      currentPathType: filesProvider.currentPathType,
                      showActions: true,
                      showHeader: false, // Hide the "SD Card" header
                      isLoading: filesProvider.isLoadingFiles,
                      onRefresh: () =>
                          filesProvider.refreshFileList(forceRefresh: true),
                      onNavigateUp: () => filesProvider.navigateUp(),
                      onFileSelected: (file) =>
                          _handleFileSelection(context, file, filesProvider),
                      onFileAction: (file, action) => _handleFileAction(
                          context, file, action, filesProvider),
                      onMultiSelectAction: (files) => _handleMultiSelectAction(
                          context, files, 'delete', filesProvider),
                      isMultiSelectMode: _isMultiSelectMode,
                      selectedFiles: _selectedFiles,
                      onFileSelectionChanged: (fileName) =>
                          _toggleFileSelection(fileName),
                    ),
                  ),
                  // Action panel for multi-selection
                  if (_isMultiSelectMode && _selectedFiles.isNotEmpty)
                    _buildMultiSelectActionBar(context),
                ],
              ),
            ),
          ), // end PopScope
        );
      },
    );
  }

  String _buildFileCountText(FilesProvider filesProvider) {
    final l10n = AppLocalizations.of(context)!;

    // Show "?" instead of previous value while loading
    if (filesProvider.isLoadingFiles) {
      return l10n.loadingFiles;
    }

    final loadedCount = filesProvider.fileList.length;
    final totalCount = filesProvider.totalFilesInDirectory;

    if (totalCount > 0) {
      return l10n.filesLoadedCount(loadedCount, totalCount);
    } else if (loadedCount > 0) {
      return l10n.filesInDirectory(loadedCount);
    } else {
      return l10n.noFiles;
    }
  }

  void _handleFileSelection(
      BuildContext context, dynamic file, FilesProvider filesProvider) {
    if (_isMultiSelectMode && !file.isDirectory) {
      // Toggle selection in multi-select mode
      _toggleFileSelection(file.name);
    } else if (file.isDirectory) {
      filesProvider.navigateToDirectory(file.name);
    } else {
      // Build full file path considering current directory
      String fullPath;
      if (filesProvider.currentPath == '/' ||
          filesProvider.currentPath.isEmpty) {
        fullPath = file.name;
      } else {
        fullPath = '${filesProvider.currentPath}/${file.name}';
      }

      if (widget.pickMode) {
        final allowed = widget.allowedExtensions;
        if (allowed != null && allowed.isNotEmpty) {
          final dot = file.name.lastIndexOf('.');
          final ext =
              dot == -1 ? '' : file.name.substring(dot + 1).toLowerCase();
          if (!allowed.contains(ext)) {
            _showInfoSnackBar(
                'Allowed: ${allowed.map((e) => '.${e.toLowerCase()}').join(', ')}');
            return;
          }
        }
        Navigator.of(context).pop({
          'path': fullPath,
          'pathType': filesProvider.currentPathType,
          'name': file.name,
        });
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => FileViewerScreen(
            fileItem: file,
            filePath: fullPath,
            pathType: filesProvider.currentPathType,
          ),
        ),
      );
    }
  }

  void _handleFileAction(BuildContext context, dynamic file, String action,
      FilesProvider filesProvider) {
    switch (action) {
      case 'navigate':
        if (file.isDirectory) {
          filesProvider.navigateToDirectory(file.name);
        }
        break;
      case 'transmit':
        _transmitFile(context, file, filesProvider);
        break;
      case 'download':
        _downloadFile(context, file, filesProvider);
        break;
      case 'copy':
        _copyFile(context, file, filesProvider);
        break;
      case 'rename':
        _renameFile(context, file, filesProvider);
        break;
      case 'delete':
        _deleteFile(context, file, filesProvider);
        break;
      case 'move':
        _moveFile(context, file, filesProvider);
        break;
    }
  }

  void _transmitFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    // Pass full file path
    final fullPath = filesProvider.currentPath == '/'
        ? file.name
        : '${filesProvider.currentPath}/${file.name}';

    await TransmitFileDialog.showAndTransmit(
      context,
      fileName: file.name,
      filePath: fullPath,
      pathType: filesProvider.currentPathType,
    );
  }

  void _downloadFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    try {
      // Build full file path considering current directory
      String fullPath;
      if (filesProvider.currentPath == '/' ||
          filesProvider.currentPath.isEmpty) {
        fullPath = file.name;
      } else {
        fullPath = '${filesProvider.currentPath}/${file.name}';
      }

      // Download file from ESP
      final content = await filesProvider.downloadFile(fullPath);

      if (content != null && context.mounted) {
        // Save file to device
        await _saveFileToDevice(context, content, file.name);
      } else if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        _showErrorSnackBar(l10n.downloadFailedNoContent);
      }
    } catch (e) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        _showErrorSnackBar(l10n.downloadFailed(e.toString()));
      }
    }
  }

  Future<void> _saveFileToDevice(
      BuildContext context, String content, String fileName) async {
    try {
      // Convert string to bytes for saving
      final bytes = Uint8List.fromList(utf8.encode(content));
      AppLogger.debug(
          '_saveFileToDevice: Starting save process for file: $fileName, size: ${bytes.length} bytes');

      // On Android and iOS, FilePicker.saveFile requires passing bytes
      final l10n = AppLocalizations.of(context)!;
      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: l10n.saveFileAs,
        fileName: fileName,
        bytes: bytes, // Pass bytes for Android/iOS
        allowedExtensions: null,
      );

      if (outputFile != null && outputFile.isNotEmpty) {
        AppLogger.debug(
            '_saveFileToDevice: File saved successfully to: $outputFile');

        // Check that the file actually exists
        final file = File(outputFile);
        if (await file.exists()) {
          final fileSize = await file.length();
          AppLogger.debug(
              '_saveFileToDevice: File verified, size: $fileSize bytes');

          if (context.mounted) {
            final l10n = AppLocalizations.of(context)!;
            _showSuccessSnackBar(l10n.fileSaved(outputFile));
          }
        } else {
          // On some platforms FilePicker saves the file itself, check after a small delay
          await Future.delayed(const Duration(milliseconds: 100));
          if (await file.exists()) {
            if (context.mounted) {
              final l10n = AppLocalizations.of(context)!;
              _showSuccessSnackBar(l10n.fileSaved(outputFile));
            }
          } else {
            throw Exception('File was not created at path: $outputFile');
          }
        }
      } else {
        AppLogger.debug(
            '_saveFileToDevice: User cancelled save dialog, copying to clipboard');
        // If user cancelled, copy to clipboard
        await Clipboard.setData(ClipboardData(text: content));

        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showInfoSnackBar(l10n.fileContentCopiedToClipboard);
        }
      }
    } catch (e) {
      AppLogger.debug('_saveFileToDevice: Error during save', e);
      // On error try to save to Documents as fallback
      try {
        AppLogger.debug(
            '_saveFileToDevice: Trying fallback to Documents directory');
        final directory = await getApplicationDocumentsDirectory();
        final file = File('${directory.path}/$fileName');
        await file.writeAsString(content);

        // Check that the file was actually saved
        if (await file.exists()) {
          final fileSize = await file.length();
          AppLogger.debug(
              '_saveFileToDevice: File saved to Documents, size: $fileSize bytes');

          if (context.mounted) {
            final l10n = AppLocalizations.of(context)!;
            _showSuccessSnackBar(l10n.fileSavedToDocuments(file.path));
          }
        } else {
          throw Exception('File was written but does not exist');
        }
      } catch (e2) {
        AppLogger.debug('_saveFileToDevice: Fallback also failed', e2);
        // Last resort - copy to clipboard
        await Clipboard.setData(ClipboardData(text: content));

        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showErrorSnackBar(l10n.couldNotSaveFile(e.toString()));
        }
      }
    }
  }

  void _copyFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    // First select destination directory
    final l10n = AppLocalizations.of(context)!;
    final directoryResult = await showDirectoryPickerDialog(
      context,
      l10n.copyFile,
      filesProvider,
    );

    if (directoryResult == null) return;

    final destinationPath = directoryResult['path'] as String;

    // Then get new file name
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        final controller = TextEditingController(text: file.name);
        return AlertDialog(
          title: Text(
            l10n.copyFile,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.destination(destinationPath),
                style: const TextStyle(color: AppColors.primaryText),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: l10n.newFileName,
                  border: const OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(l10n.copy),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty) {
      try {
        // Build full file path considering current directory
        String fullPath;
        if (filesProvider.currentPath == '/' ||
            filesProvider.currentPath.isEmpty) {
          fullPath = file.name;
        } else {
          fullPath = '${filesProvider.currentPath}/${file.name}';
        }

        // Build destination path with new name
        // destinationPath already contains full path from directoryResult
        String destPath = destinationPath;
        if (!destPath.endsWith('/')) {
          destPath = '$destPath/';
        }
        destPath = '$destPath$newName';

        // Remove leading slash if present (for relative path)
        if (destPath.startsWith('/')) {
          destPath = destPath.substring(1);
        }

        await filesProvider.copyFile(fullPath, destPath);
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showSuccessSnackBar(l10n.fileCopied(newName));
          // refreshFileList is already called in copyFile if needed
        }
      } catch (e) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showErrorSnackBar(l10n.copyFailed(e.toString()));
        }
      }
    }
  }

  void _renameFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        final controller = TextEditingController(text: file.name);
        return AlertDialog(
          title: Text(
            file.isDirectory ? l10n.renameDirectory : l10n.renameFile,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText:
                  file.isDirectory ? l10n.newDirectoryName : l10n.newFileName,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(l10n.rename),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != file.name) {
      try {
        // Build full file path considering current directory
        String fullPath;
        if (filesProvider.currentPath == '/' ||
            filesProvider.currentPath.isEmpty) {
          fullPath = file.name;
        } else {
          fullPath = '${filesProvider.currentPath}/${file.name}';
        }

        final success = await filesProvider.renameFile(fullPath, newName);
        if (context.mounted) {
          if (success) {
            // Refresh file list
            await filesProvider.refreshFileList(forceRefresh: true);

            // If the directory we are in was renamed, update path
            if (file.isDirectory) {
              final currentPath = filesProvider.currentPath;
              if (currentPath.endsWith('/${file.name}')) {
                // We are inside the renamed directory
                final pathParts = currentPath.split('/');
                pathParts[pathParts.length - 1] = newName;
                // Navigate to update path - simpler than changing directly
                // Let the user refresh manually
              } else if (currentPath == '/${file.name}' ||
                  currentPath == file.name) {
                // We are at the root of the renamed directory
                // In this case need to navigate up
                filesProvider.navigateUp();
              }
            }

            final l10n = AppLocalizations.of(context)!;
            _showSuccessSnackBar(file.isDirectory
                ? l10n.directoryRenamed(newName)
                : l10n.fileRenamed(newName));
          } else {
            final l10n = AppLocalizations.of(context)!;
            _showErrorSnackBar(
                l10n.renameFailed(file.isDirectory ? 'Directory' : 'File'));
          }
        }
      } catch (e) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showErrorSnackBar(l10n.renameFailed(e.toString()));
        }
      }
    }
  }

  void _deleteFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return AlertDialog(
          title: Text(
            file.isDirectory ? l10n.deleteDirectory : l10n.deleteFile,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: Text(
            l10n.deleteConfirm(file.name),
            style: const TextStyle(color: AppColors.primaryText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.delete),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        // Build full file path considering current directory
        String fullPath;
        if (filesProvider.currentPath == '/' ||
            filesProvider.currentPath.isEmpty) {
          fullPath = file.name;
        } else {
          fullPath = '${filesProvider.currentPath}/${file.name}';
        }

        final success = await filesProvider.deleteFile(fullPath);
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          if (success) {
            _showSuccessSnackBar(file.isDirectory
                ? l10n.directoryDeleted(file.name)
                : l10n.fileDeleted(file.name));
          } else {
            _showErrorSnackBar(
                l10n.deleteFailed('File not found or delete failed'));
          }
          await filesProvider.refreshFileList(forceRefresh: true);
        }
      } catch (e) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showErrorSnackBar(l10n.deleteFailed(e.toString()));
        }
      }
    }
  }

  void _moveFile(
      BuildContext context, dynamic file, FilesProvider filesProvider) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDirectoryPickerDialog(
      context,
      file.isDirectory ? l10n.moveDirectory : l10n.moveFile,
      filesProvider,
    );

    if (result != null && result['path'] != null) {
      final destinationPath = result['path'] as String;
      final pathType = result['pathType'] as int;

      try {
        // Build full file path considering current directory
        String sourcePath;
        if (filesProvider.currentPath == '/' ||
            filesProvider.currentPath.isEmpty) {
          sourcePath = file.name;
        } else {
          sourcePath = '${filesProvider.currentPath}/${file.name}';
        }

        // Build destination path
        String destPath = destinationPath;
        if (!destPath.endsWith('/')) {
          destPath = '$destPath/';
        }
        destPath = '$destPath${file.name}';

        // Use current pathType for source, pathType from dialog for destination
        final success = await filesProvider.moveFile(
          sourcePath,
          destPath,
          sourcePathType: filesProvider.currentPathType,
          destPathType: pathType,
        );
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          if (success) {
            _showSuccessSnackBar(file.isDirectory
                ? l10n.directoryMoved(file.name)
                : l10n.fileMoved(file.name));
            await filesProvider.refreshFileList(forceRefresh: true);
          } else {
            _showErrorSnackBar(l10n.moveFailed(file.name));
          }
        }
      } catch (e) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          _showErrorSnackBar(l10n.moveFailed(e.toString()));
        }
      }
    }
  }

  void _handleMultiSelectAction(BuildContext context, List<dynamic> files,
      String action, FilesProvider filesProvider) async {
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          final l10n = AppLocalizations.of(dialogContext)!;
          return AlertDialog(
            title: Text(
              l10n.deleteFiles,
              style: const TextStyle(color: AppColors.primaryText),
            ),
            content: Text(
              l10n.deleteFilesConfirm(files.length),
              style: const TextStyle(color: AppColors.primaryText),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.delete),
              ),
            ],
          );
        },
      );

      if (confirmed == true) {
        int successCount = 0;
        int failCount = 0;

        for (final file in files) {
          try {
            // Build full path including current directory
            String fullPath;
            if (filesProvider.currentPath == '/' ||
                filesProvider.currentPath.isEmpty) {
              fullPath = file.name;
            } else {
              fullPath = '${filesProvider.currentPath}/${file.name}';
            }
            await filesProvider.deleteFile(fullPath);
            successCount++;
          } catch (e) {
            failCount++;
            AppLogger.debug('Failed to delete ${file.name}', e);
          }
        }

        // Force refresh file list
        await filesProvider.refreshFileList(forceRefresh: true);

        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          final extra = failCount > 0 ? ', $failCount ${l10n.failed}' : '';
          _showSuccessSnackBar(l10n.deletedFilesCount(successCount, extra));

          // Reset selection only after successful deletion
          setState(() {
            _selectedFiles.clear();
            _isMultiSelectMode = false;
          });
        }
      }
    }
  }

  Widget _buildMultiSelectActionBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Text(
            AppLocalizations.of(context)!.selectedCount(_selectedFiles.length),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          const Spacer(),
          IconButton(
            onPressed: () {
              setState(() {
                _selectedFiles.clear();
              });
            },
            icon: const Icon(Icons.clear),
            tooltip: AppLocalizations.of(context)!.clearSelection,
            iconSize: 20,
          ),
          IconButton(
            onPressed: () {
              _handleMultiSelectAction(context, _selectedFileObjects, 'delete',
                  context.read<FilesProvider>());
              // Do NOT reset selection here - it will be done in _handleMultiSelectAction after successful deletion
            },
            icon: const Icon(Icons.delete),
            tooltip: AppLocalizations.of(context)!.deleteSelected,
            iconSize: 20,
          ),
        ],
      ),
    );
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) {
        _selectedFiles.clear();
      }
    });
  }

  void _toggleFileSelection(String fileName) {
    setState(() {
      if (_selectedFiles.contains(fileName)) {
        _selectedFiles.remove(fileName);
      } else {
        _selectedFiles.add(fileName);
      }
    });
  }

  List<dynamic> get _selectedFileObjects {
    final filesProvider = context.read<FilesProvider>();
    return filesProvider.fileList
        .where((file) => _selectedFiles.contains(file.name))
        .toList();
  }

  void _showSuccessSnackBar(String message) {
    final notificationProvider =
        Provider.of<NotificationProvider>(context, listen: false);
    notificationProvider.showSuccess(message);
  }

  void _showErrorSnackBar(String message) {
    final notificationProvider =
        Provider.of<NotificationProvider>(context, listen: false);
    notificationProvider.showError(message);
  }

  void _showInfoSnackBar(String message) {
    final notificationProvider =
        Provider.of<NotificationProvider>(context, listen: false);
    notificationProvider.showInfo(message);
  }

  String _getPathTypeName(BuildContext context, int pathType) {
    final l10n = AppLocalizations.of(context)!;
    switch (pathType) {
      case 0:
        return l10n.records;
      case 1:
        return l10n.captured;
      case 2:
        return l10n.presets;
      case 3:
        return l10n.temp;
      case 4:
        return l10n.internal;
      case 5:
        return 'Root';
      default:
        return l10n.unknown;
    }
  }

  Widget _buildPathWithDropdown(
      BuildContext context, FilesProvider filesProvider) {
    final pathTypeName =
        _getPathTypeName(context, filesProvider.currentPathType);
    final currentPath = filesProvider.currentPath;

    // Get path without root directory
    String pathWithoutRoot = currentPath;
    if (pathWithoutRoot.startsWith('/')) {
      pathWithoutRoot = pathWithoutRoot.substring(1);
    }

    return Row(
      children: [
        // Clickable root directory with dropdown
        PopupMenuButton<int>(
          icon: Text(
            pathTypeName,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.primaryText.withOpacity(0.7),
                ),
          ),
          onSelected: (int selectedType) {
            if (selectedType != filesProvider.currentPathType) {
              filesProvider.switchPathType(selectedType);
            }
          },
          itemBuilder: (BuildContext menuContext) {
            final l10n = AppLocalizations.of(menuContext)!;
            return [
              PopupMenuItem<int>(
                value: 0,
                child: Row(
                  children: [
                    const Icon(Icons.folder, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      l10n.records,
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 0) const Spacer(),
                    if (filesProvider.currentPathType == 0)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 1,
                child: Row(
                  children: [
                    const Icon(Icons.signal_cellular_alt, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      l10n.captured,
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 1) const Spacer(),
                    if (filesProvider.currentPathType == 1)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 2,
                child: Row(
                  children: [
                    const Icon(Icons.settings, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      l10n.presets,
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 2) const Spacer(),
                    if (filesProvider.currentPathType == 2)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 3,
                child: Row(
                  children: [
                    const Icon(Icons.timer, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      l10n.temp,
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 3) const Spacer(),
                    if (filesProvider.currentPathType == 3)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<int>(
                value: 5,
                child: Row(
                  children: [
                    const Icon(Icons.sd_card, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Root',
                      style: TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 5) const Spacer(),
                    if (filesProvider.currentPathType == 5)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 4,
                child: Row(
                  children: [
                    const Icon(Icons.memory, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      AppLocalizations.of(context)!.internalLittleFs,
                      style: const TextStyle(color: AppColors.primaryText),
                    ),
                    if (filesProvider.currentPathType == 4) const Spacer(),
                    if (filesProvider.currentPathType == 4)
                      const Icon(Icons.check,
                          size: 20, color: AppColors.primaryText),
                  ],
                ),
              ),
            ];
          },
        ),
        // Separator and path
        Text(
          '/',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.primaryText,
                fontWeight: FontWeight.w500,
              ),
        ),
        if (pathWithoutRoot.isNotEmpty)
          Expanded(
            child: Text(
              pathWithoutRoot,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.w500,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  // _showCreateDirectoryDialog and _uploadFileFromDevice extracted to
  // lib/screens/files/files_actions.dart (M4 of refactor.md).
}
