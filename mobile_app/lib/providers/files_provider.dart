import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import '../models/file_item.dart';
import '../models/directory_tree_node.dart';
import '../services/logger_service.dart';
import '../services/app_event_bus.dart';
import 'firmware_protocol.dart';

/// File system provider — manages SD card and LittleFS file operations.
///
/// Extracted from [BleProvider]: handles file listing, reading, writing,
/// renaming, deleting, moving, copying, directory management, and SD card
/// formatting. Subscribes to [MessageDispatcher.messages].
class FilesProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Callback set by owner to send a raw binary command.
  Future<bool> Function(Uint8List command, {bool withoutResponse})? sendCommand;

  /// Callback for user-facing notifications.
  void Function(String level, String message)? notify;

  FilesProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
    _connectionLostHandler = _onConnectionLost;
    AppEventBus().on<ConnectionLost>(_connectionLostHandler!);
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields
  // ══════════════════════════════════════════════════════════════

  List<FileItem> fileList = [];
  String currentPath = '/';
  int currentPathType = 5; // 0-3=relative, 4=LittleFS, 5=SD Root
  bool isLoadingFiles = false;
  double fileListProgress = 0.0;
  bool isFormattingSD = false;
  bool sdFormatSuccess = false;
  String sdFormatProgress = '';
  int totalFilesInDirectory = 0;

  // Cache for file lists
  final Map<String, List<FileItem>> _fileCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};

  // Directory tree streaming buffer
  final List<String> _streamingDirectoryTreeBuffer = [];

  // Completers for async operations
  Completer<String>? _pendingFileReadCompleter;
  bool isLoadingFileContent = false;
  double fileContentProgress = 0.0;
  Completer<bool>? _pendingFormatCompleter;
  Completer<Map<String, dynamic>>? _pendingRenameCompleter;
  Completer<Map<String, dynamic>>? _pendingDeleteCompleter;
  Completer<Map<String, dynamic>>? _pendingMkdirCompleter;
  Completer<Map<String, dynamic>>? _pendingDirectoryTreeCompleter;
  Completer<Map<String, dynamic>>? _pendingCopyCompleter;
  Completer<Map<String, dynamic>>? _pendingMoveCompleter;

  // Connection loss handler
  void Function(ConnectionLost)? _connectionLostHandler;

  // ══════════════════════════════════════════════════════════════
  //  Dispatch
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'files_list':
        _handleFilesList(msg['data']);
        break;
      case 'file_data':
        _handleFileData(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'FileSystem':
        _handleFileSystem(msg);
        break;
      case 'DirectoryTree':
        _handleFileSystem(msg); // DirectoryTree goes through same handler
        break;
      case 'FileUpload':
        _handleFileUpload(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'error':
      case 'Error':
        _handleError(msg);
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers
  // ══════════════════════════════════════════════════════════════

  void _handleFilesList(dynamic data) {
    AppLogger.debug('Files list response: $data');
    if (data is List) {
      fileList.clear();
      for (final item in data) {
        if (item is Map) {
          fileList.add(FileItem.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      isLoadingFiles = false;
      fileListProgress = 0.0;
      notifyListeners();
    }
  }

  void _handleFileData(Map<String, dynamic> data) {
    AppLogger.debug('File data response: $data');
    if (data.containsKey('content')) {
      final content = data['content'] as String? ?? '';
      if (_pendingFileReadCompleter != null &&
          !_pendingFileReadCompleter!.isCompleted) {
        _pendingFileReadCompleter!.complete(content);
        _pendingFileReadCompleter = null;
      }
    }
    isLoadingFileContent = false;
    notifyListeners();
  }

  void _handleFileSystem(dynamic data) {
    AppLogger.debug('File system response: $data');
    if (data is Map<String, dynamic>) {
      // Route binary protocol actions to their respective handlers
      final dataField = data['data'];
      if (dataField is Map) {
        final action = dataField['action'];
        if (action == 'list') {
          final listData = dataField['files'];
          if (listData is List) {
            _handleFilesList(listData);
          }
          return;
        }
        if (action == 'load') {
          _handleFileData(Map<String, dynamic>.from(dataField));
          return;
        }
      }

      // Handle DirectoryTree
      if (data['type'] == 'DirectoryTree' && data['data'] is Map) {
        final dirData = data['data'] as Map<String, dynamic>;
        if (dirData.containsKey('error')) {
          _streamingDirectoryTreeBuffer.clear();
          if (_pendingDirectoryTreeCompleter != null &&
              !_pendingDirectoryTreeCompleter!.isCompleted) {
            _pendingDirectoryTreeCompleter!
                .completeError('Error: ${dirData['error']}');
            _pendingDirectoryTreeCompleter = null;
          }
          notifyListeners();
          return;
        }

        // Accumulate streaming directory tree results
        if (dirData['streaming'] == true) {
          if (dirData['paths'] is List) {
            _streamingDirectoryTreeBuffer
                .addAll(List<String>.from(dirData['paths']));
          }
        }

        // Directory tree complete
        if (dirData['complete'] == true || dirData['streaming'] != true) {
          final paths = dirData['paths'] is List
              ? List<String>.from(dirData['paths'])
              : List<String>.from(_streamingDirectoryTreeBuffer);
          final tree = _buildDirectoryTree(paths);
          _streamingDirectoryTreeBuffer.clear();
          if (_pendingDirectoryTreeCompleter != null &&
              !_pendingDirectoryTreeCompleter!.isCompleted) {
            _pendingDirectoryTreeCompleter!
                .complete({'tree': tree, 'paths': paths});
            _pendingDirectoryTreeCompleter = null;
          }
          notifyListeners();
          return;
        }
      }

      // Handle file action results (rename, delete, mkdir, copy, move)
      if (data.containsKey('data') && data['data'] is Map) {
        final actionData = data['data'] as Map<String, dynamic>;
        final action = actionData['action'];
        final status = actionData['status'];
        final errorCode = actionData['errorCode'];
        final path = actionData['path'];

        _completeFileAction(action, status == 0,
            errorCode: errorCode, path: path);
      }
    }
  }

  void _handleFileUpload(Map<String, dynamic> data) {
    AppLogger.debug('File upload response: $data');
    final success = data['success'] == true;
    if (success) {
      notify?.call('success', 'File uploaded successfully');
    } else {
      notify?.call('error', 'File upload failed');
    }
    notifyListeners();
  }

  void _handleError(dynamic data) {
    AppLogger.debug('File operation error: $data');
    // Complete pending operations with error
    final errorMsg = data is Map
        ? (data['message'] ?? 'File operation error')
        : 'File operation error';
    _failPendingCompleters(errorMsg.toString());
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Helpers
  // ══════════════════════════════════════════════════════════════

  void _completeFileAction(int action, bool success,
      {int errorCode = 0, String? path}) {
    final completer = _completerForAction(action);
    if (completer != null && !completer.isCompleted) {
      completer.complete({
        'success': success,
        'errorCode': errorCode,
        'path': path,
      });
    }
  }

  Completer<Map<String, dynamic>>? _completerForAction(int action) {
    switch (action) {
      case 1:
        return _pendingDeleteCompleter; // delete
      case 2:
        return _pendingRenameCompleter; // rename
      case 3:
        return _pendingMkdirCompleter; // mkdir
      case 4:
        return _pendingCopyCompleter; // copy
      case 5:
        return _pendingMoveCompleter; // move
      default:
        return null;
    }
  }

  void _onConnectionLost(ConnectionLost event) {
    AppLogger.debug(
        'FilesProvider: connection lost (${event.reason}), failing pending completers');
    _failPendingCompleters('Connection lost: ${event.reason}');
    resetFileLoadingState();
  }

  void _failPendingCompleters(String message) {
    for (final c in [
      _pendingFileReadCompleter,
      _pendingFormatCompleter,
      _pendingRenameCompleter,
      _pendingDeleteCompleter,
      _pendingMkdirCompleter,
      _pendingDirectoryTreeCompleter,
      _pendingCopyCompleter,
      _pendingMoveCompleter,
    ]) {
      if (c != null && !c.isCompleted) {
        c.completeError(Exception(message));
      }
    }
    _pendingFileReadCompleter = null;
  }

  List<DirectoryTreeNode> _buildDirectoryTree(List<String> paths) {
    final root = DirectoryTreeNode(name: '/', path: '/', directories: []);
    for (final path in paths) {
      final parts = path.split('/').where((p) => p.isNotEmpty).toList();
      var current = root;
      for (final part in parts) {
        var child = current.directories.cast<DirectoryTreeNode?>().firstWhere(
              (c) => c?.name == part,
              orElse: () => null,
            );
        if (child == null) {
          final parentPath =
              current.path == '/' ? '/$part' : '${current.path}/$part';
          child =
              DirectoryTreeNode(name: part, path: parentPath, directories: []);
          current.directories.add(child);
        }
        current = child;
      }
    }
    return root.directories;
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands
  // ══════════════════════════════════════════════════════════════

  Future<void> refreshFileList({
    bool forceRefresh = false,
    int? pathType,
  }) async {
    final targetPathType = pathType ?? currentPathType;
    final cacheKey = '$targetPathType:$currentPath';

    // Check cache
    if (!forceRefresh && _fileCache.containsKey(cacheKey)) {
      final age = DateTime.now().difference(_cacheTimestamps[cacheKey]!);
      if (age.inSeconds < 5) {
        fileList = List.from(_fileCache[cacheKey]!);
        notifyListeners();
        return;
      }
    }

    isLoadingFiles = true;
    fileListProgress = 0.0;
    notifyListeners();

    final path = currentPath == '/' ? '' : currentPath;
    final cmd = FirmwareBinaryProtocol.createGetFilesListCommand(path,
        pathType: targetPathType);
    await sendCommand?.call(cmd);
  }

  Future<void> navigateToDirectory(String directoryName) async {
    if (directoryName == '..') {
      // Navigate up
      if (currentPath == '/') return;
      final parts = currentPath.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) {
        currentPath = '/';
      } else {
        parts.removeLast();
        currentPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
      }
    } else {
      // Navigate into directory
      currentPath = currentPath == '/'
          ? '/$directoryName'
          : '$currentPath/$directoryName';
    }
    notifyListeners();
    await refreshFileList(forceRefresh: true);
  }

  Future<void> navigateUp() => navigateToDirectory('..');

  Future<void> switchPathType(int type) async {
    if (type == currentPathType && currentPath == '/') return;
    currentPathType = type;
    currentPath = '/';
    notifyListeners();
    await refreshFileList(forceRefresh: true);
  }

  void clearFileCache() {
    _fileCache.clear();
    _cacheTimestamps.clear();
    notifyListeners();
  }

  void invalidateCacheForPath(String path) {
    _fileCache.remove(path);
    _cacheTimestamps.remove(path);
  }

  void resetFileLoadingState() {
    isLoadingFiles = false;
    fileListProgress = 0.0;
    isLoadingFileContent = false;
    fileContentProgress = 0.0;
    isFormattingSD = false;
    _streamingDirectoryTreeBuffer.clear();
    notifyListeners();
  }

  Future<String> readFileContent(String filePath, {int? pathType}) async {
    _pendingFileReadCompleter = Completer<String>();
    isLoadingFileContent = true;
    fileContentProgress = 0.0;
    notifyListeners();

    final cmd = FirmwareBinaryProtocol.createLoadFileDataCommand(filePath,
        pathType: pathType ?? currentPathType);
    await sendCommand?.call(cmd);

    return _pendingFileReadCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingFileReadCompleter = null;
        isLoadingFileContent = false;
        notifyListeners();
        throw Exception('File read timed out');
      },
    );
  }

  Future<String?> downloadFile(
    String filePath, {
    Function(double progress)? onProgress,
    int? pathType,
  }) async {
    _pendingFileReadCompleter = Completer<String>();
    isLoadingFileContent = true;
    fileContentProgress = 0.0;
    notifyListeners();

    final cmd = FirmwareBinaryProtocol.createLoadFileDataCommand(filePath,
        pathType: pathType ?? currentPathType);
    await sendCommand?.call(cmd);

    try {
      final content = await _pendingFileReadCompleter!.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _pendingFileReadCompleter = null;
          isLoadingFileContent = false;
          notifyListeners();
          throw Exception('Download timed out');
        },
      );
      return content;
    } catch (e) {
      isLoadingFileContent = false;
      notifyListeners();
      return null;
    }
  }

  Future<bool> renameFile(String oldPath, String newName,
      {int? pathType}) async {
    _pendingRenameCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createRenameFileCommand(oldPath, newName,
        pathType: pathType ?? currentPathType);
    await sendCommand?.call(cmd);

    final result = await _pendingRenameCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{'success': false},
    );
    return result['success'] == true;
  }

  Future<bool> deleteFile(String filePath, {int? pathType}) async {
    _pendingDeleteCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createRemoveFileCommand(filePath,
        pathType: pathType ?? currentPathType);
    await sendCommand?.call(cmd);

    final result = await _pendingDeleteCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{'success': false},
    );
    return result['success'] == true;
  }

  /// Save a file to a specific path with a chosen name. Used by the recording
  /// flow to persist captured signals.
  Future<void> saveFileToSignalsWithName(
    String sourcePath,
    String targetName, {
    int pathType = 1,
    DateTime? preserveDate,
  }) async {
    final cmd = FirmwareBinaryProtocol.createSaveToSignalsWithNameCommand(
      sourcePath,
      targetName,
      pathType: pathType,
      preserveDate: preserveDate,
    );
    await sendCommand?.call(cmd);
  }

  Future<bool> moveFile(String sourcePath, String destinationPath,
      {int? sourcePathType, int? destPathType}) async {
    _pendingMoveCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createRenameFileCommand(
        sourcePath, destinationPath,
        pathType: sourcePathType ?? currentPathType);
    await sendCommand?.call(cmd);

    final result = await _pendingMoveCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{'success': false},
    );
    return result['success'] == true;
  }

  Future<bool> copyFile(String sourcePath, String destinationPath) async {
    _pendingCopyCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createCopyFileCommand(
        sourcePath, destinationPath);
    await sendCommand?.call(cmd);

    final result = await _pendingCopyCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{'success': false},
    );
    return result['success'] == true;
  }

  Future<bool> createDirectory(String path, {int? pathType}) async {
    _pendingMkdirCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createCreateDirectoryCommand(path,
        pathType: pathType ?? currentPathType);
    await sendCommand?.call(cmd);

    final result = await _pendingMkdirCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => <String, dynamic>{'success': false},
    );
    return result['success'] == true;
  }

  Future<List<DirectoryTreeNode>> getDirectoryTree({int pathType = 0}) async {
    _pendingDirectoryTreeCompleter = Completer<Map<String, dynamic>>();
    final cmd = FirmwareBinaryProtocol.createGetDirectoryTreeCommand(
        pathType: pathType);
    await sendCommand?.call(cmd);

    final result = await _pendingDirectoryTreeCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => <String, dynamic>{'tree': [], 'paths': []},
    );
    return List<DirectoryTreeNode>.from(result['tree'] ?? []);
  }

  Future<bool> formatSDCard() async {
    _pendingFormatCompleter = Completer<bool>();
    isFormattingSD = true;
    sdFormatSuccess = false;
    sdFormatProgress = 'Starting SD card format...';
    notifyListeners();

    final cmd = FirmwareBinaryProtocol.createFormatSDCommand();
    await sendCommand?.call(cmd);

    try {
      final result = await _pendingFormatCompleter!.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () => false,
      );
      isFormattingSD = false;
      sdFormatSuccess = result;
      notifyListeners();
      return result;
    } catch (e) {
      isFormattingSD = false;
      notifyListeners();
      return false;
    }
  }

  /// Upload a local file to the device in chunks.
  /// Returns a map with 'success' (bool) and optionally 'error' (String).
  Future<Map<String, dynamic>> uploadFile(
    File file,
    String targetPath, {
    int pathType = 0,
    Function(double progress)? onProgress,
  }) async {
    if (!await file.exists()) {
      return {'success': false, 'error': 'File does not exist'};
    }

    final bytes = await file.readAsBytes();
    const chunkSize = 500;
    final totalChunks = (bytes.length + chunkSize - 1) ~/ chunkSize;
    final chunkId = DateTime.now().millisecondsSinceEpoch & 0xFF;

    // Send start command with path info
    final startCmd = FirmwareBinaryProtocol.createUploadFileStartCommand(
      targetPath,
      chunkId: chunkId,
      totalChunks: totalChunks,
    );
    await sendCommand?.call(startCmd);

    // Send data chunks
    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end =
          start + chunkSize > bytes.length ? bytes.length : start + chunkSize;
      final chunk = bytes.sublist(start, end);
      final cmd = FirmwareBinaryProtocol.createUploadFileChunkCommand(
        chunk,
        chunkId,
        i + 1,
        totalChunks,
      );
      final sent = await sendCommand?.call(cmd);
      if (sent != true) {
        return {'success': false, 'error': 'Upload failed at chunk ${i + 1}'};
      }
      onProgress?.call((i + 1) / totalChunks);
    }
    return {'success': true};
  }

  /// Upload raw bytes as a file to the device SDCard.
  /// Writes to a temp file first, then uploads via the standard pipeline.
  Future<Map<String, dynamic>> uploadFileFromBytes(
    Uint8List bytes,
    String targetPath, {
    int pathType = 0,
    Function(double progress)? onProgress,
  }) async {
    final tempFile = File(
        '${Directory.systemTemp.path}/_upload_tmp_${DateTime.now().millisecondsSinceEpoch}');
    try {
      await tempFile.writeAsBytes(bytes);
      return await uploadFile(tempFile, targetPath,
          pathType: pathType, onProgress: onProgress);
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Lifecycle
  // ══════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _subscription?.cancel();
    if (_connectionLostHandler != null) {
      AppEventBus().off<ConnectionLost>(_connectionLostHandler!);
    }
    _failPendingCompleters('Provider disposed');
    super.dispose();
  }
}
