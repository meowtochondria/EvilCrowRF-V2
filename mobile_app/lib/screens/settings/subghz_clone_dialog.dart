import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:provider/provider.dart';
import '../../providers/files_provider.dart';
import '../../services/flipper_subdb_service.dart';
import '../../services/logger_service.dart';
import '../../theme/app_colors.dart';

/// Dialog that handles the full SubGHz DB clone workflow with progress.
///
/// Extracted from `settings_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md` — see the file-splitting plan there.
class SubGhzCloneDialog extends StatefulWidget {
  final FilesProvider filesProvider;
  const SubGhzCloneDialog({super.key, required this.filesProvider});

  @override
  State<SubGhzCloneDialog> createState() => _SubGhzCloneDialogState();

  /// Convenience entry point used from `SettingsScreen`.
  static Future<void> show(BuildContext context) {
    final filesProvider = context.read<FilesProvider>();
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => SubGhzCloneDialog(filesProvider: filesProvider),
    );
  }
}

class _SubGhzCloneDialogState extends State<SubGhzCloneDialog> {
  String _phase = 'init';
  String _statusText = 'Preparing...';
  double _progress = 0.0;
  int _totalFiles = 0;
  int _uploadedFiles = 0;
  int _failedFiles = 0;
  bool _isDone = false;
  bool _hasError = false;
  String _errorMessage = '';

  // Pause / Resume state
  bool _isPaused = false;
  bool _pauseRequested = false;
  bool _checkingResume = true;
  bool _hasResumableSession = false;
  Set<String> _completedPaths = {};

  @override
  void initState() {
    super.initState();
    _checkForResumableSession();
  }

  /// On open, check if a previous session can be resumed.
  Future<void> _checkForResumableSession() async {
    final hasResume = await FlipperSubDbService.hasResumableSession();
    if (!mounted) return;
    if (hasResume) {
      final completed = await FlipperSubDbService.loadCompletedFiles();
      setState(() {
        _checkingResume = false;
        _hasResumableSession = true;
        _completedPaths = completed;
        _statusText =
            'Previous session found (${completed.length} files already uploaded). Resume or start fresh?';
      });
    } else {
      setState(() {
        _checkingResume = false;
        _hasResumableSession = false;
      });
      _startCloning(resume: false);
    }
  }

  /// Pause the current upload. Finishes the file in progress, then stops.
  void _pauseCloning() {
    setState(() {
      _pauseRequested = true;
      _statusText = 'Pausing after current file...';
    });
  }

  /// Resume a paused or previously-saved session.
  void _resumeCloning() {
    setState(() {
      _isPaused = false;
      _pauseRequested = false;
      _hasResumableSession = false;
    });
    _startCloning(resume: true);
  }

  Future<void> _startCloning({required bool resume}) async {
    // Keep screen awake during the entire cloning process
    WakelockPlus.enable();
    try {
      List<SubFileEntry> subFiles;

      if (resume) {
        // ── Resume path: re-extract from cached ZIP ──
        setState(() {
          _phase = 'extract';
          _statusText = 'Loading cached database...';
          _progress = 0.0;
        });

        final cachedZip = await FlipperSubDbService.loadCachedZip();
        if (cachedZip == null) {
          setState(() {
            _isDone = true;
            _hasError = true;
            _errorMessage = 'Cached ZIP not found. Please start a fresh clone.';
          });
          WakelockPlus.disable();
          return;
        }

        // Load previously completed files
        _completedPaths = await FlipperSubDbService.loadCompletedFiles();

        subFiles = FlipperSubDbService.extractFromBytes(
          cachedZip,
          onProgress: (phase, detail, fraction) {
            if (mounted) {
              setState(() {
                _phase = phase;
                _statusText = detail;
                _progress = fraction;
              });
            }
          },
        );
      } else {
        // ── Fresh start: download and extract ──
        _completedPaths = {};
        await FlipperSubDbService.clearCache();

        setState(() {
          _phase = 'download';
          _statusText = 'Downloading SubGHz database from GitHub...';
          _progress = 0.0;
        });

        subFiles = await FlipperSubDbService.downloadAndExtract(
          onProgress: (phase, detail, fraction) {
            if (mounted) {
              setState(() {
                _phase = phase;
                _statusText = detail;
                _progress = fraction;
              });
            }
          },
          onZipDownloaded: (zipBytes) async {
            // Cache the raw ZIP for potential resume
            await FlipperSubDbService.cacheZipBytes(zipBytes);
          },
        );
      }

      if (subFiles.isEmpty) {
        setState(() {
          _isDone = true;
          _hasError = true;
          _errorMessage = 'No .sub files found in the repository';
        });
        WakelockPlus.disable();
        return;
      }

      _totalFiles = subFiles.length;
      _uploadedFiles = _completedPaths.length;

      // Phase 3: Create base directory on SDCard
      setState(() {
        _phase = 'upload';
        _statusText = 'Creating "SUB Files" folder on SDCard...';
        _progress = _completedPaths.length / _totalFiles;
      });

      await widget.filesProvider
          .createDirectory(FlipperSubDbService.sdTargetFolder, pathType: 5);
      await Future.delayed(const Duration(milliseconds: 200));

      // Collect all unique subdirectories and create them
      final subdirs = <String>{};
      for (final file in subFiles) {
        final parts = file.relativePath.split('/');
        if (parts.length > 1) {
          // Build cumulative subdir paths
          for (int i = 1; i < parts.length; i++) {
            final subdir =
                '${FlipperSubDbService.sdTargetFolder}/${parts.sublist(0, i).join('/')}';
            subdirs.add(subdir);
          }
        }
      }

      // Create subdirectories (sorted so parents come first)
      final sortedDirs = subdirs.toList()..sort();
      for (final dir in sortedDirs) {
        if (_pauseRequested) break;
        setState(() {
          _statusText = 'Creating folder: $dir';
        });
        try {
          await widget.filesProvider.createDirectory(dir, pathType: 5);
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          // Directory might already exist, continue
        }
      }

      // Phase 4: Upload files one at a time
      for (int i = 0; i < subFiles.length; i++) {
        // ── Check for pause after each file ──
        if (_pauseRequested) {
          await FlipperSubDbService.saveProgress(_completedPaths);
          if (mounted) {
            setState(() {
              _isPaused = true;
              _pauseRequested = false;
              _statusText =
                  'Paused – $_uploadedFiles / $_totalFiles files uploaded. You can close and resume later.';
            });
          }
          WakelockPlus.disable();
          return;
        }

        final file = subFiles[i];

        // Skip already-uploaded files (from a previous session)
        if (_completedPaths.contains(file.relativePath)) {
          continue;
        }

        final targetPath =
            '${FlipperSubDbService.sdTargetFolder}/${file.relativePath}';

        if (mounted) {
          setState(() {
            _statusText =
                'Uploading (${_uploadedFiles + 1}/$_totalFiles): ${file.relativePath}';
            _progress = _uploadedFiles / _totalFiles;
          });
        }

        try {
          await widget.filesProvider.uploadFileFromBytes(
            file.content,
            targetPath,
            pathType: 5,
          );
          _completedPaths.add(file.relativePath);
          _uploadedFiles = _completedPaths.length;

          // Persist progress every 10 files for safety
          if (_uploadedFiles % 10 == 0) {
            await FlipperSubDbService.saveProgress(_completedPaths);
          }

          // Pace uploads to avoid BLE congestion
          await Future.delayed(const Duration(milliseconds: 150));
        } catch (e) {
          _failedFiles++;
          // Log but continue with other files
          AppLogger.severe('Failed to upload ${file.relativePath}', e);
        }
      }

      // All files processed – clean up cache
      await FlipperSubDbService.clearCache();

      if (mounted) {
        setState(() {
          _isDone = true;
          _uploadedFiles = _totalFiles;
          _progress = 1.0;
          _statusText = _failedFiles > 0
              ? 'Completed with $_failedFiles errors'
              : 'All $_totalFiles files uploaded successfully!';
        });
      }
      // Release wakelock after successful completion
      WakelockPlus.disable();
    } catch (e) {
      // On error, save progress so user can resume later
      if (_completedPaths.isNotEmpty) {
        await FlipperSubDbService.saveProgress(_completedPaths);
      }
      // Release wakelock on error
      WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _isDone = true;
          _hasError = true;
          _errorMessage = e.toString();
          _statusText = 'Error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // While checking for resumable session, show a spinner
    if (_checkingResume) {
      return AlertDialog(
        title: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            const Text('Clone SubGHz DB', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: const Text('Checking for previous session...'),
      );
    }

    // If a resumable session was found, show Resume / Start Fresh options
    if (_hasResumableSession && !_isPaused && _phase == 'init') {
      return AlertDialog(
        title: Row(
          children: [
            Icon(Icons.replay, color: AppColors.statusOrange),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Resume Clone?', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: Text(
          '${_completedPaths.length} files were uploaded in a previous session.\n'
          'Resume where you left off, or start fresh?',
          style: TextStyle(color: AppColors.primaryText, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () {
              setState(() {
                _hasResumableSession = false;
                _completedPaths = {};
              });
              _startCloning(resume: false);
            },
            child: const Text('Start Fresh'),
          ),
          ElevatedButton(
            onPressed: _resumeCloning,
            child: const Text('Resume'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _isDone
                ? (_hasError ? Icons.error_outline : Icons.check_circle)
                : _isPaused
                    ? Icons.pause_circle
                    : Icons.cloud_download,
            color: _isDone
                ? (_hasError ? AppColors.error : AppColors.success)
                : _isPaused
                    ? AppColors.statusOrange
                    : AppColors.statusOrange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isDone
                  ? (_hasError ? 'Clone Failed' : 'Clone Complete')
                  : _isPaused
                      ? 'Clone Paused'
                      : 'Cloning SubGHz Database',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Phase indicator
          if (!_isDone && !_isPaused) ...[
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.statusOrange),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _phase == 'download'
                      ? 'Phase 1/3: Downloading'
                      : _phase == 'extract'
                          ? 'Phase 2/3: Extracting'
                          : 'Phase 3/3: Uploading to SDCard',
                  style: TextStyle(
                    color: AppColors.primaryAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // Status text
          Text(
            _statusText,
            style: TextStyle(
              color: _hasError ? AppColors.error : AppColors.primaryText,
              fontSize: 12,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _isDone ? 1.0 : (_progress > 0 ? _progress : null),
              backgroundColor: AppColors.greyLight.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                _hasError
                    ? AppColors.error
                    : _isDone
                        ? AppColors.success
                        : _isPaused
                            ? AppColors.statusOrange
                            : AppColors.statusOrange,
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),

          // File counter (during upload phase)
          if (_phase == 'upload' || _isDone || _isPaused)
            Text(
              '$_uploadedFiles / $_totalFiles files'
              '${_failedFiles > 0 ? ' ($_failedFiles failed)' : ''}',
              style: TextStyle(
                color: AppColors.secondaryText,
                fontSize: 11,
              ),
            ),

          // Error message
          if (_hasError && _errorMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _errorMessage,
                style: TextStyle(color: AppColors.error, fontSize: 11),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
      actions: [
        // Close button when done, paused, or errored
        if (_isDone || _isPaused)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),

        // Resume button when paused
        if (_isPaused)
          ElevatedButton.icon(
            onPressed: _resumeCloning,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Resume'),
          ),

        // Pause button during upload (only while actively uploading)
        if (!_isDone && !_isPaused && _phase == 'upload' && !_pauseRequested)
          ElevatedButton.icon(
            onPressed: _pauseCloning,
            icon: const Icon(Icons.pause, size: 18),
            label: const Text('Pause'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusOrange,
            ),
          ),

        // Show "Pausing..." indicator when pause is requested
        if (_pauseRequested && !_isPaused)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}
