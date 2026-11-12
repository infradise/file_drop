import 'package:flutter/foundation.dart' show TargetPlatform, Uint8List;

import 'channel.dart';
import 'file_item.dart';
import 'mime_types.dart';
import 'platform/platform_bridge.dart';
import 'selector_types.dart';

bool get _isMobileTargetPlatform =>
    !isWebRuntime &&
    (effectiveNativePlatform == TargetPlatform.android ||
        effectiveNativePlatform == TargetPlatform.iOS);

/// Opens a file selection dialog for picking a single file.
///
/// Filters selectable files using [acceptedTypeGroups]. Starts in
/// [initialDirectory] when provided, and customizes the confirmation button
/// label with [confirmButtonText] when supported by the host OS.
///
/// Returns `null` if the user cancels the dialog.
Future<XFile?> openFile({
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  _validateTypeGroups(acceptedTypeGroups);
  if (isWebRuntime) {
    final picked = await platformOpenFiles(
      acceptedTypeGroups: acceptedTypeGroups,
      allowMultiple: false,
    );
    if (picked.isEmpty) {
      return null;
    }
    return XFile.fromPlatformData(picked.first);
  }
  final raw = await DesktopDrop.channel.invokeMethod<Object?>(
    'openFile',
    <String, dynamic>{
      'acceptedTypeGroups': _serializeTypeGroups(acceptedTypeGroups),
      'initialDirectory': initialDirectory,
      'confirmButtonText': confirmButtonText,
    },
  );
  final parsed = _parseSinglePickedXFile(raw);
  if (parsed != null) {
    return parsed;
  }
  if (raw is List<Object?> && raw.isNotEmpty) {
    return _parseSinglePickedXFile(raw.first);
  }
  return null;
}

/// Opens a file selection dialog allowing multiple files to be chosen.
///
/// Filters selectable files using [acceptedTypeGroups]. Starts in
/// [initialDirectory] when provided, and customizes the confirmation button
/// label with [confirmButtonText] when supported by the host OS.
///
/// Returns an empty list if the user cancels the dialog.
Future<List<XFile>> openFiles({
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  _validateTypeGroups(acceptedTypeGroups);
  if (isWebRuntime) {
    final picked = await platformOpenFiles(
      acceptedTypeGroups: acceptedTypeGroups,
      allowMultiple: true,
    );
    if (picked.isEmpty) {
      return const <XFile>[];
    }
    return picked.map(XFile.fromPlatformData).toList(growable: false);
  }
  final raw = await DesktopDrop.channel.invokeMethod<List<Object?>>(
    'openFiles',
    <String, dynamic>{
      'acceptedTypeGroups': _serializeTypeGroups(acceptedTypeGroups),
      'initialDirectory': initialDirectory,
      'confirmButtonText': confirmButtonText,
    },
  );
  if (raw == null || raw.isEmpty) {
    return const <XFile>[];
  }
  return raw
      .map(_parseSinglePickedXFile)
      .whereType<XFile>()
      .toList(growable: false);
}

/// Opens a native file save dialog and returns the chosen [FileSaveLocation].
///
/// Filters file types using [acceptedTypeGroups], pre-populates the file name
/// field with [suggestedName], opens at [initialDirectory], customizes the
/// confirmation button with [confirmButtonText], and controls folder creation
/// via [canCreateDirectories] when supported by the platform.
///
/// Throws [UnsupportedError] on Android, iOS, and Web because mobile and
/// browser sandboxes do not expose raw pre-save filesystem paths; use
/// [saveFile] to save bytes across all 6 platforms.
///
/// Returns `null` if the user cancels the dialog.
Future<FileSaveLocation?> getSaveLocation({
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  String? initialDirectory,
  String? suggestedName,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  if (isWebRuntime) {
    throw UnsupportedError(
      'Browsers do not expose raw local filesystem paths on Web. '
      'Use saveFile(bytes: ...) instead.',
    );
  }
  if (_isMobileTargetPlatform) {
    throw UnsupportedError(
      'Mobile platforms (Android and iOS) do not expose raw pre-save '
      'filesystem paths. Use saveFile(bytes: ...) instead.',
    );
  }
  _validateTypeGroups(acceptedTypeGroups);
  final raw = await DesktopDrop.channel.invokeMethod<Object?>(
    'getSaveLocation',
    <String, dynamic>{
      'acceptedTypeGroups': _serializeTypeGroups(acceptedTypeGroups),
      'initialDirectory': initialDirectory,
      'suggestedName': suggestedName,
      'confirmButtonText': confirmButtonText,
      if (canCreateDirectories != null)
        'canCreateDirectories': canCreateDirectories,
    },
  );
  if (raw == null) {
    return null;
  }
  if (raw is String) {
    return raw.isEmpty ? null : FileSaveLocation(raw);
  }
  if (raw is Map<Object?, Object?>) {
    final path = raw['path'];
    if (path is! String || path.isEmpty) {
      return null;
    }
    XTypeGroup? activeFilter;
    final filterIndex = raw['activeFilterIndex'];
    if (filterIndex is int &&
        filterIndex >= 0 &&
        filterIndex < acceptedTypeGroups.length) {
      activeFilter = acceptedTypeGroups[filterIndex];
    }
    return FileSaveLocation(path, activeFilter: activeFilter);
  }
  return null;
}

/// Opens a native file save dialog and returns the chosen save file path.
///
/// Convenience wrapper around [getSaveLocation] providing 1:1 compatibility
/// with legacy `getSavePath` callers. Throws [UnsupportedError] on Android,
/// iOS, and Web; use [saveFile] to write bytes across all 6 platforms. Returns
/// `null` if cancelled.
Future<String?> getSavePath({
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  String? initialDirectory,
  String? suggestedName,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  if (isWebRuntime) {
    throw UnsupportedError(
      'Browsers do not expose raw local filesystem paths on Web. '
      'Use saveFile(bytes: ...) instead.',
    );
  }
  if (_isMobileTargetPlatform) {
    throw UnsupportedError(
      'Mobile platforms (Android and iOS) do not expose raw pre-save '
      'filesystem paths. Use saveFile(bytes: ...) instead.',
    );
  }
  final location = await getSaveLocation(
    acceptedTypeGroups: acceptedTypeGroups,
    initialDirectory: initialDirectory,
    suggestedName: suggestedName,
    confirmButtonText: confirmButtonText,
    canCreateDirectories: canCreateDirectories,
  );
  return location?.path;
}

/// Prompts the user to save [bytes] and writes them to the selected
/// destination across Desktop, Mobile, and Web/Wasm.
///
/// When [mimeType] is provided, it is forwarded to native/browser export flows
/// (such as Android SAF `ACTION_CREATE_DOCUMENT` and Web `Blob` downloads) and
/// synthesized into [acceptedTypeGroups] when [acceptedTypeGroups] is empty.
///
/// - **Desktop (`macOS`, `Windows`, `Linux`)**: Opens [getSaveLocation] and
///   writes [bytes] to the chosen path, returning the saved file path or `null`
///   if cancelled.
/// - **Mobile (`Android`, `iOS`)**: Invokes `'saveFile'` over the native
///   platform channel (using SAF `ACTION_CREATE_DOCUMENT` on Android or
///   `UIDocumentPickerViewController` export on iOS) and returns the saved
///   destination URI/path or `null` if cancelled.
/// - **Web / Wasm**: Uses the File System Access API (`showSaveFilePicker`) on
///   Chromium browsers (returning `null` on cancellation) and falls back to an
///   `<a download>` `Blob` download on Safari and Firefox.
Future<String?> saveFile({
  required Uint8List bytes,
  String? suggestedName,
  String? mimeType,
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  String? initialDirectory,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  _validateTypeGroups(acceptedTypeGroups);
  final trimmedMime = mimeType?.trim();
  final effectiveMime =
      (trimmedMime != null && trimmedMime.isNotEmpty) ? trimmedMime : null;
  final effectiveTypeGroups =
      (acceptedTypeGroups.isNotEmpty || effectiveMime == null)
          ? acceptedTypeGroups
          : <XTypeGroup>[
              XTypeGroup(
                mimeTypes: <String>[effectiveMime],
                extensions: _extractSaveExtensionList(suggestedName),
              ),
            ];
  if (isWebRuntime) {
    return platformSaveFileOnWeb(
      bytes: bytes,
      suggestedName: suggestedName,
      mimeType: effectiveMime,
      acceptedTypeGroups: effectiveTypeGroups,
    );
  }
  if (_isMobileTargetPlatform) {
    final raw = await DesktopDrop.channel.invokeMethod<Object?>(
      'saveFile',
      <String, dynamic>{
        'bytes': bytes,
        'suggestedName': suggestedName,
        if (effectiveMime != null) 'mimeType': effectiveMime,
        'acceptedTypeGroups': _serializeTypeGroups(effectiveTypeGroups),
        'initialDirectory': initialDirectory,
        'confirmButtonText': confirmButtonText,
        if (canCreateDirectories != null)
          'canCreateDirectories': canCreateDirectories,
      },
    );
    if (raw is String) {
      return raw.isEmpty ? null : raw;
    }
    if (raw is Map<Object?, Object?>) {
      final pathOrUri = raw['path'] ?? raw['uri'];
      if (pathOrUri is String && pathOrUri.isNotEmpty) {
        return pathOrUri;
      }
    }
    return null;
  }
  final location = await getSaveLocation(
    acceptedTypeGroups: effectiveTypeGroups,
    initialDirectory: initialDirectory,
    suggestedName: suggestedName,
    confirmButtonText: confirmButtonText,
    canCreateDirectories: canCreateDirectories,
  );
  if (location == null) {
    return null;
  }
  await platformWriteBytesToPath(
    location.path,
    bytes,
    suggestedName: suggestedName,
    mimeType: effectiveMime,
  );
  return location.path;
}

/// Opens a native directory selection dialog for picking a single folder.
///
/// Starts in [initialDirectory] when provided, customizes the confirmation
/// button with [confirmButtonText], and controls new directory creation via
/// [canCreateDirectories] when supported.
///
/// Throws [UnsupportedError] on Web because browsers do not expose raw local
/// directory paths. Returns `null` if the user cancels the dialog.
Future<String?> getDirectoryPath({
  String? initialDirectory,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  if (isWebRuntime) {
    throw UnsupportedError(
      'Browsers do not expose raw local directory paths on Web.',
    );
  }
  final raw = await DesktopDrop.channel.invokeMethod<Object?>(
    'getDirectoryPath',
    <String, dynamic>{
      'initialDirectory': initialDirectory,
      'confirmButtonText': confirmButtonText,
      if (canCreateDirectories != null)
        'canCreateDirectories': canCreateDirectories,
    },
  );
  if (raw is String && raw.isNotEmpty) {
    return raw;
  }
  if (raw is List<Object?> && raw.isNotEmpty) {
    final first = raw.first;
    if (first is String && first.isNotEmpty) {
      return first;
    }
  }
  return null;
}

/// Opens a native directory selection dialog allowing multiple folders to be
/// chosen.
///
/// Throws [UnsupportedError] on Android (where Storage Access Framework only
/// supports single-tree selection via [getDirectoryPath] / [openDirectory]) and
/// on Web (where browsers do not expose raw local directory paths). Returns an
/// empty list if the user cancels the dialog.
Future<List<String>> getDirectoryPaths({
  String? initialDirectory,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  if (isWebRuntime) {
    throw UnsupportedError(
      'Browsers do not expose raw local directory paths on Web.',
    );
  }
  if (effectiveNativePlatform == TargetPlatform.android) {
    throw UnsupportedError(
      'Android Storage Access Framework (ACTION_OPEN_DOCUMENT_TREE) only '
      'supports selecting a single directory. Use getDirectoryPath() or '
      'openDirectory() instead.',
    );
  }
  final raw = await DesktopDrop.channel.invokeMethod<List<Object?>>(
    'getDirectoryPaths',
    <String, dynamic>{
      'initialDirectory': initialDirectory,
      'confirmButtonText': confirmButtonText,
      if (canCreateDirectories != null)
        'canCreateDirectories': canCreateDirectories,
    },
  );
  if (raw == null || raw.isEmpty) {
    return const <String>[];
  }
  return raw
      .whereType<String>()
      .where((String path) => path.isNotEmpty)
      .toList(growable: false);
}

/// Opens a directory selection dialog and returns an [XDirectory] whose
/// contents can be enumerated via `XDirectory.list()`.
///
/// - **Desktop & iOS**: Delegates to [getDirectoryPath] and wraps the selected
///   folder in a [DropDirectoryItem].
/// - **Android**: Invokes `'openDirectory'` on the native channel (supporting
///   SAF document tree URIs where `localPath` is `null` as well as local
///   paths) and returns a [DropDirectoryItem].
/// - **Web**: Throws [UnsupportedError].
Future<XDirectory?> openDirectory({
  String? initialDirectory,
  String? confirmButtonText,
  bool? canCreateDirectories,
}) async {
  if (isWebRuntime) {
    throw UnsupportedError('openDirectory is not supported on Web.');
  }
  if (effectiveNativePlatform == TargetPlatform.android) {
    final raw = await DesktopDrop.channel.invokeMethod<Object?>(
      'openDirectory',
      <String, dynamic>{
        'initialDirectory': initialDirectory,
        'confirmButtonText': confirmButtonText,
        if (canCreateDirectories != null)
          'canCreateDirectories': canCreateDirectories,
      },
    );
    if (raw == null) {
      return null;
    }
    if (raw is String) {
      if (raw.isEmpty) {
        return null;
      }
      if (raw.startsWith('content://')) {
        final dirName = extractPathBasename(raw);
        return DropDirectoryItem.fromPlatformBacking(
          path: raw,
          name: dirName,
          backing: createChannelDirectoryBacking(raw, name: dirName),
        );
      }
      return DropDirectoryItem.fromPath(raw);
    }
    if (raw is Map<Object?, Object?>) {
      final rawUri = raw['uri'] as String?;
      final rawPath = (raw['path'] as String?) ?? rawUri ?? '';
      if (rawPath.isEmpty && (rawUri == null || rawUri.isEmpty)) {
        return null;
      }
      final isContent = (raw['isContentUri'] == true) ||
          rawPath.startsWith('content://') ||
          (rawUri != null && rawUri.startsWith('content://'));
      final effectiveUri = rawUri ?? rawPath;
      final dirName = (raw['name'] as String?) ??
          extractPathBasename(rawPath.isNotEmpty ? rawPath : effectiveUri);
      if (isContent) {
        return DropDirectoryItem.fromPlatformBacking(
          path: effectiveUri,
          name: dirName,
          backing: createChannelDirectoryBacking(effectiveUri, name: dirName),
        );
      }
      return DropDirectoryItem.fromPath(rawPath, name: dirName);
    }
    return null;
  }

  final path = await getDirectoryPath(
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
    canCreateDirectories: canCreateDirectories,
  );
  if (path == null || path.isEmpty) {
    return null;
  }
  return DropDirectoryItem.fromPath(path);
}

/// Clears temporary cached picker/drop files on Mobile (`Android`, `iOS`) and
/// revokes tracked `Blob` object URLs on Web.
///
/// Returns `true` when native temporary cache files were deleted on Mobile, or
/// `false` on Desktop and Web without throwing.
Future<bool> clearTemporaryFiles() async {
  if (isWebRuntime) {
    return platformClearTemporaryFiles();
  }
  if (_isMobileTargetPlatform) {
    final result = await DesktopDrop.channel.invokeMethod<bool>(
      'clearTemporaryFiles',
    );
    return result ?? false;
  }
  return platformClearTemporaryFiles();
}

XFile? _parseSinglePickedXFile(Object? raw) {
  if (raw is String) {
    if (raw.isEmpty) {
      return null;
    }
    if (raw.startsWith('content://')) {
      return XFile.fromPlatformData(
        PlatformPickedFileData(
          path: raw,
          name: extractPathBasename(raw),
          localPath: null,
          backing: createChannelFileBacking(raw),
        ),
      );
    }
    return XFile(raw);
  }
  if (raw is Map<Object?, Object?>) {
    final rawUri = raw['uri'] as String?;
    final rawPath = (raw['path'] as String?) ?? rawUri ?? '';
    if (rawPath.isEmpty && (rawUri == null || rawUri.isEmpty)) {
      return null;
    }
    final isContent = (raw['isContentUri'] == true) ||
        rawPath.startsWith('content://') ||
        (rawUri != null && rawUri.startsWith('content://'));
    final effectiveUri = rawUri ?? rawPath;
    final name = (raw['name'] as String?) ??
        extractPathBasename(rawPath.isNotEmpty ? rawPath : effectiveUri);
    final mimeType = raw['mimeType'] as String?;
    final length = (raw['length'] as num?)?.toInt();
    final modifiedMs = (raw['lastModified'] as num?)?.toInt();
    final lastModified = modifiedMs != null
        ? DateTime.fromMillisecondsSinceEpoch(modifiedMs)
        : null;
    if (isContent) {
      return XFile.fromPlatformData(
        PlatformPickedFileData(
          path: effectiveUri,
          name: name,
          mimeType: mimeType,
          length: length,
          lastModified: lastModified,
          localPath: null,
          backing: createChannelFileBacking(effectiveUri),
        ),
      );
    }
    return XFile(
      rawPath,
      name: name,
      mimeType: mimeType,
      length: length,
      lastModified: lastModified,
    );
  }
  return null;
}

List<String>? _extractSaveExtensionList(String? suggestedName) {
  if (suggestedName == null || suggestedName.isEmpty) {
    return null;
  }
  final base = extractPathBasename(suggestedName);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot >= base.length - 1) {
    return null;
  }
  final ext = base.substring(dot + 1).trim();
  return ext.isEmpty ? null : <String>[ext];
}

List<Map<String, dynamic>> _serializeTypeGroups(List<XTypeGroup> groups) {
  return groups.map((XTypeGroup g) => g.toMap()).toList(growable: false);
}

void _validateTypeGroups(List<XTypeGroup> groups) {
  for (final _ in groups) {
    // Reserved hook for platform filter validation if needed.
  }
}
