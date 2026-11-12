import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform;
import 'package:flutter/services.dart';

import '../mime_types.dart';
import '../selector_types.dart';
import 'platform_types.dart';

/// Whether the current runtime is executing on Web / WebAssembly.
const bool isWebRuntime = false;

/// Resolves the active native [TargetPlatform], honoring
/// [debugDefaultTargetPlatformOverride] when set in tests and otherwise using
/// the real host OS from `dart:io` so `TestWidgetsFlutterBinding`'s default
/// Android theme override does not misroute desktop calls.
TargetPlatform get effectiveNativePlatform {
  final override = debugDefaultTargetPlatformOverride;
  if (override != null) {
    return override;
  }
  if (Platform.isAndroid) {
    return TargetPlatform.android;
  }
  if (Platform.isIOS) {
    return TargetPlatform.iOS;
  }
  if (Platform.isMacOS) {
    return TargetPlatform.macOS;
  }
  if (Platform.isWindows) {
    return TargetPlatform.windows;
  }
  if (Platform.isLinux) {
    return TargetPlatform.linux;
  }
  return defaultTargetPlatform;
}

const MethodChannel _ioChannel = MethodChannel(kFileDropChannelName);

bool _isContentUri(String path) => path.startsWith('content://');

/// Synchronously checks whether [path] refers to an existing local directory.
bool platformIsDirectorySync(String path) {
  if (path.isEmpty || _isContentUri(path)) {
    return false;
  }
  return FileSystemEntity.isDirectorySync(path);
}

/// Checks whether [path] exists on the local filesystem or via a `content://`
/// URI.
Future<bool> platformPathExists(String path, {bool? isDirectoryHint}) async {
  if (path.isEmpty) {
    return false;
  }
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).exists();
  }
  if (isDirectoryHint == true) {
    return Directory(path).exists();
  }
  if (isDirectoryHint == false) {
    return File(path).exists();
  }
  final type = await FileSystemEntity.type(path);
  return type != FileSystemEntityType.notFound;
}

/// Returns the byte length of the file at [path].
Future<int> platformReadLength(String path) {
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).length();
  }
  return File(path).length();
}

/// Reads all bytes from the file at [path].
Future<Uint8List> platformReadBytes(String path) {
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).readAsBytes();
  }
  return File(path).readAsBytes();
}

/// Reads and decodes the file at [path] using [encoding].
Future<String> platformReadString(
  String path, {
  Encoding encoding = utf8,
}) {
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).readAsString(encoding: encoding);
  }
  return File(path).readAsString(encoding: encoding);
}

/// Opens a byte stream over [path] from [start] (inclusive) to [end]
/// (exclusive).
Stream<Uint8List> platformOpenRead(String path, [int? start, int? end]) {
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).openRead(start, end);
  }
  return File(path).openRead(start, end).map(
        (List<int> chunk) =>
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      );
}

/// Returns the last-modified timestamp of [path].
Future<DateTime> platformLastModified(String path) {
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).lastModified();
  }
  return File(path).lastModified();
}

/// Copies the file at [sourcePath] to [targetPath].
Future<void> platformCopyPathTo(String sourcePath, String targetPath) async {
  if (_isContentUri(sourcePath)) {
    await _ChannelContentUriFileBacking(sourcePath).saveTo(targetPath);
    return;
  }
  await File(sourcePath).copy(targetPath);
}

/// Writes [bytes] directly to [targetPath] on disk.
Future<void> platformSaveBytesTo(
  String targetPath,
  Uint8List bytes, {
  String? fallbackName,
  String? mimeType,
}) async {
  await File(targetPath).writeAsBytes(bytes);
}

/// Writes [bytes] to [path] on disk, throwing [FileSystemException] when [path]
/// is empty.
Future<PlatformFileBacking?> platformWriteBytesToPath(
  String path,
  Uint8List bytes, {
  String? suggestedName,
  String? mimeType,
}) async {
  if (path.isEmpty) {
    throw const FileSystemException(
      'Cannot writeAsBytes on an item without a filesystem path',
    );
  }
  if (_isContentUri(path)) {
    return _ChannelContentUriFileBacking(path).writeAsBytes(
      bytes,
      suggestedName: suggestedName ?? '',
      mimeType: mimeType,
    );
  }
  await File(path).writeAsBytes(bytes);
  return null;
}

/// Streams immediate child files and directories inside [path].
Stream<PlatformDirectoryEntry> platformListDirectoryPath(String path) async* {
  if (_isContentUri(path)) {
    yield* _ChannelDirectoryBacking(path).list();
    return;
  }
  await for (final entity in Directory(path).list(followLinks: false)) {
    final childPath = entity.path;
    final childName = extractPathBasename(childPath);
    if (entity is Directory) {
      yield PlatformChildDirectory(
        name: childName,
        path: childPath,
        localPath: childPath,
      );
    } else {
      yield PlatformChildFile(
        name: childName,
        path: childPath,
        localPath: childPath,
      );
    }
  }
}

/// Creates a `MethodChannel`-backed [PlatformFileBacking] for a mobile
/// `content://` [uri].
PlatformFileBacking createChannelFileBacking(String uri) =>
    _ChannelContentUriFileBacking(uri);

/// Creates a `MethodChannel`-backed [PlatformDirectoryBacking] for a mobile
/// SAF [uri].
PlatformDirectoryBacking createChannelDirectoryBacking(
  String uri, {
  String? name,
}) =>
    _ChannelDirectoryBacking(uri, name: name);

/// Stub on native platforms where `openFile` / `openFiles` use `MethodChannel`.
Future<List<PlatformPickedFileData>> platformOpenFiles({
  required List<XTypeGroup> acceptedTypeGroups,
  required bool allowMultiple,
}) {
  throw UnsupportedError(
    'platformOpenFiles Web picker is only used on Web runtimes.',
  );
}

/// Stub on native platforms where `saveFile` uses native dialogs or channels.
Future<String?> platformSaveFileOnWeb({
  required Uint8List bytes,
  String? suggestedName,
  String? mimeType,
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
}) {
  throw UnsupportedError('platformSaveFileOnWeb is only used on Web runtimes.');
}

/// Cleans up temporary browser resources; returns `false` on desktop IO.
Future<bool> platformClearTemporaryFiles() => Future<bool>.value(false);

/// No-op on native platforms because drag events arrive over `MethodChannel`.
void ensureWebDropInitialized(WebDropCallbacks callbacks) {}

final class _ChannelContentUriFileBacking implements PlatformFileBacking {
  const _ChannelContentUriFileBacking(this._uri);

  final String _uri;

  @override
  String? get localPath => null;

  @override
  String get uri => _uri;

  Future<Map<Object?, Object?>?> _stat() {
    return _ioChannel.invokeMethod<Map<Object?, Object?>>(
      'statContentUri',
      <String, dynamic>{'uri': _uri},
    );
  }

  @override
  Future<bool> exists() async {
    final stat = await _stat();
    if (stat == null) {
      return false;
    }
    return (stat['exists'] as bool?) ?? true;
  }

  @override
  Future<int> length() async {
    final stat = await _stat();
    final rawLength = stat?['length'];
    if (rawLength is num) {
      return rawLength.toInt();
    }
    final bytes = await readAsBytes();
    return bytes.length;
  }

  @override
  Future<DateTime> lastModified() async {
    final stat = await _stat();
    final rawModified = stat?['lastModified'];
    if (rawModified is num) {
      return DateTime.fromMillisecondsSinceEpoch(rawModified.toInt());
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = await _ioChannel.invokeMethod<Uint8List>(
      'readContentUri',
      <String, dynamic>{'uri': _uri},
    );
    return bytes ?? Uint8List(0);
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final bytes = await readAsBytes();
    return encoding.decode(bytes);
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    const chunkSize = 256 * 1024;
    var offset = (start ?? 0) < 0 ? 0 : (start ?? 0);
    final limit = end;
    if (limit != null && limit <= offset) {
      return;
    }
    while (limit == null || offset < limit) {
      final nextEnd = limit == null
          ? offset + chunkSize
          : (offset + chunkSize < limit ? offset + chunkSize : limit);
      final requestedLength = nextEnd - offset;
      final bytes = await _ioChannel.invokeMethod<Uint8List>(
        'readContentUri',
        <String, dynamic>{
          'uri': _uri,
          'start': offset,
          'end': nextEnd,
        },
      );
      if (bytes == null || bytes.isEmpty) {
        break;
      }
      if (bytes.length > requestedLength) {
        // Fallback when a mock or host ignores `start`/`end` and returns all bytes.
        final effectiveStart = offset.clamp(0, bytes.length);
        final effectiveEnd =
            (limit ?? bytes.length).clamp(effectiveStart, bytes.length);
        if (effectiveStart < effectiveEnd) {
          yield bytes.sublist(effectiveStart, effectiveEnd);
        }
        break;
      }
      yield bytes;
      offset += bytes.length;
      if (bytes.length < requestedLength) {
        break;
      }
    }
  }

  @override
  Future<void> saveTo(String targetPath) async {
    final bytes = await readAsBytes();
    await File(targetPath).writeAsBytes(bytes);
  }

  @override
  Future<PlatformFileBacking?> writeAsBytes(
    Uint8List bytes, {
    required String suggestedName,
    String? mimeType,
  }) async {
    await _ioChannel.invokeMethod<void>(
      'writeContentUri',
      <String, dynamic>{
        'uri': _uri,
        'bytes': bytes,
      },
    );
    return this;
  }
}

final class _ChannelDirectoryBacking implements PlatformDirectoryBacking {
  _ChannelDirectoryBacking(this._uri, {String? name}) : _resolvedName = name;

  String _uri;
  String? _resolvedName;

  @override
  String? get localPath => null;

  @override
  String get uri => _uri;

  @override
  String? get resolvedName => _resolvedName;

  @override
  void updateGrantedAccess({required String uri, String? name}) {
    _uri = uri;
    if (name != null && name.isNotEmpty) {
      _resolvedName = name;
    }
  }

  @override
  Future<bool> exists() async {
    final stat = await _ioChannel.invokeMethod<Map<Object?, Object?>>(
      'statContentUri',
      <String, dynamic>{'uri': _uri},
    );
    if (stat == null) {
      return false;
    }
    return (stat['exists'] as bool?) ?? true;
  }

  @override
  Stream<PlatformDirectoryEntry> list() async* {
    final entries = await _ioChannel.invokeMethod<List<Object?>>(
      'listDirectory',
      <String, dynamic>{
        'uri': _uri,
        'path': _uri,
      },
    );
    if (entries == null) {
      return;
    }
    for (final raw in entries) {
      if (raw is! Map<Object?, Object?>) {
        continue;
      }
      final entryUri =
          (raw['uri'] as String?) ?? (raw['path'] as String?) ?? '';
      final entryPath = (raw['path'] as String?) ?? entryUri;
      if (entryUri.isEmpty && entryPath.isEmpty) {
        continue;
      }
      final entryName =
          (raw['name'] as String?) ?? extractPathBasename(entryPath);
      final isDir = raw['isDirectory'] == true;
      final isContent = (raw['isContentUri'] == true) ||
          entryUri.startsWith('content://') ||
          entryPath.startsWith('content://');
      final local =
          isContent ? null : (raw['localPath'] as String? ?? entryPath);

      if (isDir) {
        yield PlatformChildDirectory(
          name: entryName,
          path: isContent ? entryUri : entryPath,
          localPath: local,
          backing: isContent
              ? _ChannelDirectoryBacking(entryUri, name: entryName)
              : null,
        );
      } else {
        yield PlatformChildFile(
          name: entryName,
          path: isContent ? entryUri : entryPath,
          localPath: local,
          mimeType: raw['mimeType'] as String?,
          backing: isContent ? _ChannelContentUriFileBacking(entryUri) : null,
        );
      }
    }
  }
}
