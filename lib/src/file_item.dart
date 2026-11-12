import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import 'mime_types.dart';
import 'platform/platform_bridge.dart';

export 'mime_types.dart' show inferMimeTypeFromPath;

String _resolvePathFromUri(Uri uri) {
  if (uri.scheme == 'file' || uri.scheme.isEmpty) {
    return isWebRuntime ? uri.toFilePath(windows: false) : uri.toFilePath();
  }
  return uri.toString();
}

/// Unified cross-platform file, directory, or string drop reference for
/// `file_drop`.
///
/// Replaces `XEntity`, `XFile`, and `XDirectory` from `cross_file` (`0.3.x` and
/// `0.4.x`) as well as `DropItem` from `desktop_drop` (`0.8.x` and `0.9.2`)
/// across Android, iOS, Linux, macOS, Windows, and Web/Wasm with zero external
/// hosted dependencies.
@immutable
class FileDropItem {
  /// Creates a [FileDropItem] referencing a filesystem [path], object URL, or
  /// in-memory [bytes].
  const FileDropItem(
    this.path, {
    String? name,
    this.mimeType,
    int? length,
    Uint8List? bytes,
    DateTime? lastModified,
    this.extraAppleBookmark,
    this.fromPromise = false,
    bool? isDirectory,
  })  : _name = name,
        _length = length,
        _bytes = bytes,
        _lastModified = lastModified,
        _isDirectory = isDirectory,
        _fileBacking = null;

  /// Creates an in-memory [FileDropItem] backed directly by [bytes].
  const FileDropItem.fromData(
    Uint8List bytes, {
    this.mimeType,
    String? path,
    String? name,
    int? length,
    DateTime? lastModified,
    this.extraAppleBookmark,
    this.fromPromise = false,
    bool? isDirectory,
  })  : path = path ?? '',
        _name = name,
        _length = length,
        _bytes = bytes,
        _lastModified = lastModified,
        _isDirectory = isDirectory,
        _fileBacking = null;

  const FileDropItem._backed(
    this.path, {
    required PlatformFileBacking backing,
    String? name,
    this.mimeType,
    int? length,
    DateTime? lastModified,
    this.extraAppleBookmark,
    this.fromPromise = false,
    bool? isDirectory,
  })  : _name = name,
        _length = length,
        _bytes = null,
        _lastModified = lastModified,
        _isDirectory = isDirectory,
        _fileBacking = backing;

  /// Creates a [FileDropItem] backed by platform-specific file metadata and a
  /// [PlatformPickedFileData] handle (such as a browser `Blob` or Android
  /// `content://` URI).
  factory FileDropItem.fromPlatformData(
    PlatformPickedFileData data, {
    Uint8List? extraAppleBookmark,
    bool fromPromise = false,
  }) {
    final backing = data.backing;
    if (backing != null) {
      return FileDropItem._backed(
        data.path,
        backing: backing,
        name: data.name,
        mimeType: data.mimeType,
        length: data.length,
        lastModified: data.lastModified,
        extraAppleBookmark: extraAppleBookmark,
        fromPromise: fromPromise,
        isDirectory: false,
      );
    }
    return FileDropItem(
      data.path,
      name: data.name,
      mimeType: data.mimeType,
      length: data.length,
      lastModified: data.lastModified,
      extraAppleBookmark: extraAppleBookmark,
      fromPromise: fromPromise,
      isDirectory: false,
    );
  }

  /// Creates a filesystem-backed [FileDropItem] matching `XFile.fileSystem`
  /// from `cross_file 0.4.x`.
  factory FileDropItem.fileSystem({required String path}) => FileDropItem(path);

  /// Creates a [FileDropItem] from a `file://`, `content://`, or `blob:` [uri].
  factory FileDropItem.fromUri(Uri uri) {
    if (!isWebRuntime && uri.scheme == 'content') {
      final uriStr = uri.toString();
      return FileDropItem._backed(
        uriStr,
        backing: createChannelFileBacking(uriStr),
        isDirectory: false,
      );
    }
    return FileDropItem(_resolvePathFromUri(uri));
  }

  /// The filesystem path, `content://` URI, or Web object URL of this item, or
  /// an empty string if created purely from in-memory bytes or string data.
  final String path;

  /// Optional MIME type explicitly supplied at construction time.
  final String? mimeType;

  /// Optional macOS security-scoped bookmark data when dropped from outside
  /// the application sandbox container.
  final Uint8List? extraAppleBookmark;

  /// Whether this item was materialized from a native file promise into a
  /// temporary drop folder.
  final bool fromPromise;

  final String? _name;
  final int? _length;
  final Uint8List? _bytes;
  final DateTime? _lastModified;
  final bool? _isDirectory;
  final PlatformFileBacking? _fileBacking;

  /// Self-reference matching `DropFileItem.file` in `desktop_drop 0.9.2`.
  FileDropItem get file => this;

  /// Local filesystem path when backed by a local file or directory, or `null`
  /// on Web, Android `content://` URIs, and purely in-memory items
  /// (`desktop_drop 0.9.2` parity).
  String? get localPath {
    if (isWebRuntime) {
      return null;
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.localPath;
    }
    if (path.isEmpty || path.startsWith('content://')) {
      return null;
    }
    return path;
  }

  /// Alias for [extraAppleBookmark] matching `desktop_drop 0.9.2`.
  Uint8List? get appleBookmark => extraAppleBookmark;

  /// Alias for [fromPromise] matching `desktop_drop 0.9.2`.
  bool get isPromised => fromPromise;

  /// URI representation of [path] matching `XEntity.uri` in `cross_file 0.4.x`.
  String get uri {
    final backing = _fileBacking;
    if (backing != null && backing.uri.isNotEmpty) {
      return backing.uri;
    }
    if (path.isEmpty) {
      return '';
    }
    if (path.startsWith('content://') ||
        path.startsWith('blob:') ||
        path.startsWith('file://') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return path;
    }
    return Uri.file(path, windows: _looksLikeWindowsPath(path)).toString();
  }

  /// The base filename or directory name extracted from [path] across both
  /// POSIX (`/`) and Windows (`\`) path separators.
  String get name {
    if (_name != null) {
      return _name;
    }
    return extractPathBasename(path);
  }

  /// Whether this item represents a directory.
  ///
  /// Uses the cached native directory flag when provided, falling back to the
  /// platform bridge when [path] is non-empty on native OSes.
  bool get isDirectory {
    if (_isDirectory != null) {
      return _isDirectory;
    }
    if (path.isEmpty || _fileBacking != null) {
      return false;
    }
    return platformIsDirectorySync(path);
  }

  /// Returns whether the referenced file or directory exists (`XEntity.exists`
  /// parity for `cross_file 0.4.x`).
  Future<bool> exists() {
    if (_bytes != null) {
      return Future<bool>.value(true);
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.exists();
    }
    if (path.isEmpty) {
      return Future<bool>.value(false);
    }
    return platformPathExists(path, isDirectoryHint: _isDirectory);
  }

  /// Returns the length of the file in bytes.
  Future<int> length() {
    if (_length != null) {
      return Future<int>.value(_length);
    }
    final bytes = _bytes;
    if (bytes != null) {
      return Future<int>.value(bytes.length);
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.length();
    }
    return platformReadLength(path);
  }

  /// Reads the entire file contents as a [Uint8List].
  Future<Uint8List> readAsBytes() {
    final bytes = _bytes;
    if (bytes != null) {
      return Future<Uint8List>.value(Uint8List.fromList(bytes));
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.readAsBytes();
    }
    return platformReadBytes(path);
  }

  /// Reads the entire file contents decoded using [encoding] (defaults to
  /// [utf8]).
  Future<String> readAsString({Encoding encoding = utf8}) {
    final bytes = _bytes;
    if (bytes != null) {
      return Future<String>.sync(() => encoding.decode(bytes));
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.readAsString(encoding: encoding);
    }
    return platformReadString(path, encoding: encoding);
  }

  /// Opens an independent byte [Stream] over the file contents from [start]
  /// (inclusive) to [end] (exclusive).
  Stream<Uint8List> openRead([int? start, int? end]) {
    if (start != null && start < 0) {
      return Stream<Uint8List>.error(
        RangeError('`start` must be >= 0. start: $start'),
      );
    }
    if (end != null && end < (start ?? 0)) {
      return Stream<Uint8List>.error(
        RangeError(
          '`end` must be >= `start`. start: $start, end: $end',
        ),
      );
    }
    final bytes = _bytes;
    if (bytes != null) {
      return _openBytesStream(bytes, start, end);
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.openRead(start, end);
    }
    return platformOpenRead(path, start, end);
  }

  /// Returns the last-modified timestamp of the file.
  Future<DateTime> lastModified() {
    if (_lastModified != null) {
      return Future<DateTime>.value(_lastModified);
    }
    final backing = _fileBacking;
    if (backing != null) {
      return backing.lastModified();
    }
    return platformLastModified(path);
  }

  /// Copies, writes, or downloads the contents of this item to [targetPath].
  Future<void> saveTo(String targetPath) async {
    final bytes = _bytes;
    if (bytes != null) {
      await platformSaveBytesTo(
        targetPath,
        bytes,
        fallbackName: name,
        mimeType: mimeType,
      );
      return;
    }
    final backing = _fileBacking;
    if (backing != null) {
      await backing.saveTo(targetPath);
      return;
    }
    await platformCopyPathTo(path, targetPath);
  }

  /// Writes [bytes] to [path] (or triggers a browser download on Web) and
  /// returns an updated [FileDropItem] (`FileSystemXFile.writeAsBytes` parity
  /// for `cross_file 0.4.x`).
  Future<FileDropItem> writeAsBytes(Uint8List bytes) async {
    final backing = _fileBacking;
    if (backing != null) {
      final updatedBacking = await backing.writeAsBytes(
        bytes,
        suggestedName: name,
        mimeType: mimeType,
      );
      if (updatedBacking != null) {
        return FileDropItem._backed(
          updatedBacking.uri,
          backing: updatedBacking,
          name: name,
          mimeType: mimeType,
          length: bytes.length,
          extraAppleBookmark: extraAppleBookmark,
          fromPromise: fromPromise,
          isDirectory: false,
        );
      }
    }
    final newBacking = await platformWriteBytesToPath(
      path,
      bytes,
      suggestedName: name,
      mimeType: mimeType,
    );
    if (newBacking != null) {
      return FileDropItem._backed(
        newBacking.uri,
        backing: newBacking,
        name: _name ?? (name.isEmpty ? 'download' : name),
        mimeType: mimeType,
        length: bytes.length,
        extraAppleBookmark: extraAppleBookmark,
        fromPromise: fromPromise,
        isDirectory: false,
      );
    }
    return FileDropItem(
      path,
      name: _name,
      mimeType: mimeType,
      extraAppleBookmark: extraAppleBookmark,
      fromPromise: fromPromise,
      isDirectory: false,
    );
  }

  static Stream<Uint8List> _openBytesStream(
    Uint8List bytes,
    int? start,
    int? end,
  ) async* {
    final effectiveStart = (start ?? 0).clamp(0, bytes.length);
    final effectiveEnd = (end ?? bytes.length).clamp(
      effectiveStart,
      bytes.length,
    );
    yield bytes.sublist(effectiveStart, effectiveEnd);
  }

  static bool _looksLikeWindowsPath(String rawPath) {
    if (rawPath.startsWith(r'\\')) {
      return true;
    }
    return rawPath.length >= 2 &&
        rawPath.codeUnitAt(1) == 0x3A /* : */ &&
        ((rawPath.codeUnitAt(0) >= 0x41 && rawPath.codeUnitAt(0) <= 0x5A) ||
            (rawPath.codeUnitAt(0) >= 0x61 && rawPath.codeUnitAt(0) <= 0x7A));
  }

  @override
  String toString() =>
      'FileDropItem(path: $path, name: $name, isDirectory: $isDirectory)';
}

/// A dropped regular file item delivered by `DropTarget` (`desktop_drop 0.8.x`
/// compatible base class).
class DropItemFile extends FileDropItem {
  /// Creates a [DropItemFile] for a regular file at [path].
  const DropItemFile(
    super.path, {
    super.name,
    super.mimeType,
    super.length,
    super.bytes,
    super.lastModified,
    Uint8List? extraAppleBookmark,
    Uint8List? appleBookmark,
    bool fromPromise = false,
    bool? isPromised,
  }) : super(
          extraAppleBookmark: extraAppleBookmark ?? appleBookmark,
          fromPromise: isPromised ?? fromPromise,
          isDirectory: false,
        );

  /// Creates an in-memory [DropItemFile] backed by [bytes].
  const DropItemFile.fromData(
    super.bytes, {
    super.mimeType,
    super.path,
    super.name,
    super.length,
    super.lastModified,
    Uint8List? extraAppleBookmark,
    Uint8List? appleBookmark,
    bool fromPromise = false,
    bool? isPromised,
  }) : super.fromData(
          extraAppleBookmark: extraAppleBookmark ?? appleBookmark,
          fromPromise: isPromised ?? fromPromise,
          isDirectory: false,
        );

  /// Creates a [DropItemFile] from a filesystem [path].
  factory DropItemFile.fromPath(
    String path, {
    String? name,
    String? mimeType,
    Uint8List? appleBookmark,
    bool isPromised = false,
  }) =>
      DropFileItem.fromPath(
        path,
        name: name,
        mimeType: mimeType,
        appleBookmark: appleBookmark,
        isPromised: isPromised,
      );

  /// Creates a [DropItemFile] from a `file://` or `content://` [uri].
  factory DropItemFile.fromUri(Uri uri) =>
      DropItemFile(_resolvePathFromUri(uri));
}

/// A dropped file item matching `DropFileItem` in `desktop_drop 0.9.2` while
/// also satisfying `is DropItemFile` for `desktop_drop 0.8.x` callers.
class DropFileItem extends DropItemFile {
  /// Creates a [DropFileItem] wrapping [file].
  const DropFileItem({
    required FileDropItem file,
    required String name,
    super.mimeType,
    String? localPath,
    Uint8List? appleBookmark,
    bool isPromised = false,
  })  : _wrappedFile = file,
        _explicitLocalPath = localPath,
        super(
          localPath ?? '',
          name: name,
          extraAppleBookmark: appleBookmark,
          fromPromise: isPromised,
        );

  /// Creates a [DropFileItem] backed by a local filesystem [path].
  factory DropFileItem.fromPath(
    String path, {
    String? name,
    String? mimeType,
    Uint8List? appleBookmark,
    bool isPromised = false,
  }) {
    final baseFile = FileDropItem.fileSystem(path: path);
    return DropFileItem(
      file: baseFile,
      name: name ?? baseFile.name,
      mimeType: mimeType,
      localPath: isWebRuntime ? null : path,
      appleBookmark: appleBookmark,
      isPromised: isPromised,
    );
  }

  /// Creates a [DropFileItem] from a [PlatformPickedFileData] handle (such as a
  /// Web `File` `Blob` or Android `content://` URI, where `localPath` is
  /// `null`).
  factory DropFileItem.fromPlatformData(
    PlatformPickedFileData data, {
    Uint8List? appleBookmark,
    bool isPromised = false,
  }) {
    final baseFile = FileDropItem.fromPlatformData(
      data,
      extraAppleBookmark: appleBookmark,
      fromPromise: isPromised,
    );
    return DropFileItem(
      file: baseFile,
      name: data.name,
      mimeType: data.mimeType,
      localPath: isWebRuntime ? null : data.localPath,
      appleBookmark: appleBookmark,
      isPromised: isPromised,
    );
  }

  final FileDropItem _wrappedFile;
  final String? _explicitLocalPath;

  @override
  FileDropItem get file => _wrappedFile;

  @override
  String? get localPath => isWebRuntime ? null : _explicitLocalPath;

  @override
  String get path => _explicitLocalPath ?? _wrappedFile.path;

  @override
  String get uri => _wrappedFile.uri;

  @override
  String? get mimeType =>
      inferMimeTypeFromPath(super.mimeType, name, _explicitLocalPath);

  @override
  Future<bool> exists() =>
      _explicitLocalPath != null ? super.exists() : _wrappedFile.exists();

  @override
  Future<int> length() => _wrappedFile.length();

  @override
  Future<Uint8List> readAsBytes() => _wrappedFile.readAsBytes();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _wrappedFile.readAsString(encoding: encoding);

  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      _wrappedFile.openRead(start, end);

  @override
  Future<DateTime> lastModified() => _wrappedFile.lastModified();

  @override
  Future<void> saveTo(String targetPath) => _wrappedFile.saveTo(targetPath);

  @override
  Future<FileDropItem> writeAsBytes(Uint8List bytes) =>
      _wrappedFile.writeAsBytes(bytes);
}

/// A dropped directory item delivered by `DropTarget` (`desktop_drop 0.8.x`
/// and `XDirectory` `cross_file 0.4.x` compatible class).
class DropItemDirectory extends FileDropItem {
  /// Creates a [DropItemDirectory] for a directory at [path].
  const DropItemDirectory(
    super.path, {
    this.children = const <FileDropItem>[],
    super.name,
    super.mimeType,
    super.length,
    super.bytes,
    super.lastModified,
    Uint8List? extraAppleBookmark,
    Uint8List? appleBookmark,
    bool fromPromise = false,
    bool? isPromised,
  })  : _directoryBacking = null,
        super(
          extraAppleBookmark: extraAppleBookmark ?? appleBookmark,
          fromPromise: isPromised ?? fromPromise,
          isDirectory: true,
        );

  /// Creates an in-memory [DropItemDirectory] backed by [bytes].
  const DropItemDirectory.fromData(
    super.bytes, {
    this.children = const <FileDropItem>[],
    super.mimeType,
    super.path,
    super.name,
    super.length,
    super.lastModified,
    Uint8List? extraAppleBookmark,
    Uint8List? appleBookmark,
    bool fromPromise = false,
    bool? isPromised,
  })  : _directoryBacking = null,
        super.fromData(
          extraAppleBookmark: extraAppleBookmark ?? appleBookmark,
          fromPromise: isPromised ?? fromPromise,
          isDirectory: true,
        );

  const DropItemDirectory._backed(
    super.path, {
    required PlatformDirectoryBacking backing,
    super.name,
    super.extraAppleBookmark,
    super.fromPromise,
  })  : _directoryBacking = backing,
        children = const <FileDropItem>[],
        super(isDirectory: true);

  /// Creates a [DropItemDirectory] backed by a [PlatformDirectoryBacking] (such
  /// as a Web `FileSystemDirectoryEntry` or Android SAF tree URI).
  factory DropItemDirectory.fromPlatformBacking({
    required String path,
    required String name,
    required PlatformDirectoryBacking backing,
    Uint8List? appleBookmark,
    bool isPromised = false,
  }) =>
      DropItemDirectory._backed(
        path,
        backing: backing,
        name: name,
        extraAppleBookmark: appleBookmark,
        fromPromise: isPromised,
      );

  /// Creates a filesystem-backed [DropItemDirectory] matching
  /// `XDirectory.fileSystem` in `cross_file 0.4.x`.
  factory DropItemDirectory.fileSystem({required String path}) =>
      DropItemDirectory(path);

  /// Creates a [DropItemDirectory] from a `file://` or `content://` [uri].
  factory DropItemDirectory.fromUri(Uri uri) {
    if (!isWebRuntime && uri.scheme == 'content') {
      final uriStr = uri.toString();
      final dirName = extractPathBasename(uriStr);
      return DropItemDirectory._backed(
        uriStr,
        backing: createChannelDirectoryBacking(uriStr, name: dirName),
        name: dirName,
      );
    }
    return DropItemDirectory(_resolvePathFromUri(uri));
  }

  /// Optional child items belonging to this directory.
  final List<FileDropItem> children;

  final PlatformDirectoryBacking? _directoryBacking;

  /// Self-reference matching `DropDirectoryItem.directory` in
  /// `desktop_drop 0.9.2`.
  DropItemDirectory get directory => this;

  @override
  String? get localPath {
    if (isWebRuntime) {
      return null;
    }
    final backing = _directoryBacking;
    if (backing != null) {
      return backing.localPath;
    }
    return super.localPath;
  }

  @override
  String get path {
    final backing = _directoryBacking;
    if (backing != null && backing.uri.isNotEmpty) {
      return backing.uri;
    }
    return super.path;
  }

  @override
  String get uri {
    final backing = _directoryBacking;
    if (backing != null && backing.uri.isNotEmpty) {
      return backing.uri;
    }
    return super.uri;
  }

  @override
  String get name {
    final resolved = _directoryBacking?.resolvedName;
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }
    return super.name;
  }

  @override
  Future<bool> exists() {
    final backing = _directoryBacking;
    if (backing != null) {
      return backing.exists();
    }
    return super.exists();
  }

  /// Updates the underlying directory backing handle when scoped directory
  /// access is granted at runtime (for example on Android SAF).
  void updatePlatformDirectoryAccess({
    required String grantedUri,
    String? grantedName,
  }) {
    _directoryBacking?.updateGrantedAccess(uri: grantedUri, name: grantedName);
  }

  /// Lists immediate child files and directories without reading file contents
  /// (`XDirectory.list` parity for `cross_file 0.4.x` and `desktop_drop 0.9.2`).
  Stream<FileDropItem> list() async* {
    final backing = _directoryBacking;
    if (backing != null) {
      await for (final child in backing.list()) {
        yield _mapPlatformDirectoryChild(child);
      }
      return;
    }
    if (path.isEmpty) {
      for (final child in children) {
        yield child;
      }
      return;
    }
    await for (final child in platformListDirectoryPath(path)) {
      yield _mapPlatformDirectoryChild(child);
    }
  }

  static FileDropItem _mapPlatformDirectoryChild(PlatformDirectoryEntry child) {
    switch (child) {
      case PlatformChildDirectory():
        final childBacking = child.backing;
        if (childBacking != null) {
          return DropDirectoryItem.fromPlatformBacking(
            path: child.path,
            name: child.name,
            backing: childBacking,
          );
        }
        return DropDirectoryItem.fromPath(
          child.path,
          name: child.name,
        );
      case PlatformChildFile():
        final childBacking = child.backing;
        if (childBacking != null) {
          return DropFileItem.fromPlatformData(
            PlatformPickedFileData(
              path: child.path,
              name: child.name,
              mimeType: child.mimeType,
              localPath: child.localPath,
              backing: childBacking,
            ),
          );
        }
        return DropFileItem.fromPath(
          child.path,
          name: child.name,
          mimeType: child.mimeType,
        );
    }
  }
}

/// A dropped directory item matching `DropDirectoryItem` in
/// `desktop_drop 0.9.2` while also satisfying `is DropItemDirectory` for
/// `desktop_drop 0.8.x` callers.
class DropDirectoryItem extends DropItemDirectory {
  /// Creates a [DropDirectoryItem] wrapping [directory].
  const DropDirectoryItem({
    required DropItemDirectory directory,
    required String name,
    String? localPath,
    Uint8List? appleBookmark,
    bool isPromised = false,
    super.children,
  })  : _wrappedDirectory = directory,
        _explicitLocalPath = localPath,
        super(
          localPath ?? '',
          name: name,
          extraAppleBookmark: appleBookmark,
          fromPromise: isPromised,
        );

  /// Creates a [DropDirectoryItem] backed by a local filesystem [path].
  factory DropDirectoryItem.fromPath(
    String path, {
    String? name,
    Uint8List? appleBookmark,
    bool isPromised = false,
    List<FileDropItem> children = const <FileDropItem>[],
  }) {
    final baseDir = DropItemDirectory.fileSystem(path: path);
    return DropDirectoryItem(
      directory: baseDir,
      name: name ?? baseDir.name,
      localPath: isWebRuntime ? null : path,
      appleBookmark: appleBookmark,
      isPromised: isPromised,
      children: children,
    );
  }

  /// Creates a [DropDirectoryItem] backed by a [PlatformDirectoryBacking]
  /// (where [localPath] is `null`, such as Web `FileSystemDirectoryEntry` or
  /// Android SAF `content://` tree URIs).
  factory DropDirectoryItem.fromPlatformBacking({
    required String path,
    required String name,
    required PlatformDirectoryBacking backing,
    Uint8List? appleBookmark,
    bool isPromised = false,
  }) {
    final baseDir = DropItemDirectory.fromPlatformBacking(
      path: path,
      name: name,
      backing: backing,
      appleBookmark: appleBookmark,
      isPromised: isPromised,
    );
    return DropDirectoryItem(
      directory: baseDir,
      name: name,
      localPath: isWebRuntime ? null : backing.localPath,
      appleBookmark: appleBookmark,
      isPromised: isPromised,
    );
  }

  final DropItemDirectory _wrappedDirectory;
  final String? _explicitLocalPath;

  @override
  DropItemDirectory get directory => _wrappedDirectory;

  @override
  String? get localPath => isWebRuntime ? null : _explicitLocalPath;

  @override
  String get path => _explicitLocalPath ?? _wrappedDirectory.path;

  @override
  String get uri => _wrappedDirectory.uri;

  @override
  String get name => _explicitLocalPath == null &&
          _wrappedDirectory.path.startsWith('content://') &&
          _wrappedDirectory.name.isNotEmpty
      ? _wrappedDirectory.name
      : (super.name.isNotEmpty ? super.name : _wrappedDirectory.name);

  @override
  String? get mimeType => null;

  @override
  Future<bool> exists() =>
      _explicitLocalPath != null ? super.exists() : _wrappedDirectory.exists();

  @override
  void updatePlatformDirectoryAccess({
    required String grantedUri,
    String? grantedName,
  }) {
    _wrappedDirectory.updatePlatformDirectoryAccess(
      grantedUri: grantedUri,
      grantedName: grantedName,
    );
  }

  @override
  Stream<FileDropItem> list() => _wrappedDirectory.list();
}

/// A dropped string representation (`text/plain`, `text/html`, `text/uri-list`,
/// or custom string MIME types) matching `desktop_drop 0.9.2`.
class DropStringItem extends FileDropItem {
  /// Creates a [DropStringItem] with [mimeType] and [value].
  const DropStringItem({
    required String mimeType,
    required this.value,
  })  : _stringMimeType = mimeType,
        super('', name: '', mimeType: mimeType, isDirectory: false);

  final String _stringMimeType;

  /// String content delivered by the drag source.
  final String value;

  @override
  String get mimeType => _stringMimeType;

  @override
  String? get localPath => null;

  @override
  Future<int> length() => Future<int>.value(utf8.encode(value).length);

  @override
  Future<Uint8List> readAsBytes() =>
      Future<Uint8List>.value(Uint8List.fromList(utf8.encode(value)));

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      Future<String>.value(value);

  @override
  String toString() => 'DropStringItem(mimeType: $mimeType, value: $value)';
}

/// Drop-in type alias matching `XEntity` from `cross_file 0.4.x`.
typedef XEntity = FileDropItem;

/// Drop-in type alias matching `XFile` from `file_selector` and `cross_file`.
typedef XFile = FileDropItem;

/// Drop-in type alias matching `FileSystemXFile` from `cross_file 0.4.x`.
typedef FileSystemXFile = DropItemFile;

/// Drop-in type alias matching `XDirectory` from `cross_file 0.4.x`.
typedef XDirectory = DropItemDirectory;

/// Drop-in type alias matching `FileSystemXDirectory` from `cross_file 0.4.x`.
typedef FileSystemXDirectory = DropItemDirectory;

/// Drop-in type alias matching `DropItem` from `desktop_drop`.
typedef DropItem = FileDropItem;
