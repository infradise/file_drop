import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../selector_types.dart';

/// Shared platform channel name used across native desktop and mobile bridges.
const String kFileDropChannelName = 'com.infradise.file_drop';

/// Builds a comma-separated HTML `<input type="file" accept="...">` value from
/// [groups], returning an empty string when all file types are allowed.
String buildWebAcceptAttribute(List<XTypeGroup> groups) {
  if (groups.isEmpty || groups.any((XTypeGroup g) => g.allowsAll)) {
    return '';
  }
  final tokens = <String>{};
  for (final group in groups) {
    final mimeTypes = group.mimeTypes;
    if (mimeTypes != null) {
      for (final mime in mimeTypes) {
        final trimmed = mime.trim();
        if (trimmed.isNotEmpty) {
          tokens.add(trimmed);
        }
      }
    }
    final wildCards = group.webWildCards;
    if (wildCards != null) {
      for (final wildCard in wildCards) {
        final trimmed = wildCard.trim();
        if (trimmed.isNotEmpty) {
          tokens.add(trimmed);
        }
      }
    }
    final extensions = group.extensions;
    if (extensions != null) {
      for (final ext in extensions) {
        final trimmed = ext.trim();
        if (trimmed.isNotEmpty) {
          tokens.add('.$trimmed');
        }
      }
    }
  }
  return tokens.join(',');
}

/// Platform-specific backing handle for non-filesystem or browser-managed file
/// items (such as Web `Blob`/`File` handles or Android `content://` URIs).
abstract interface class PlatformFileBacking {
  /// Local filesystem path if backed by a real OS path, or `null` for virtual,
  /// Web `Blob`, or Android `content://` items.
  String? get localPath;

  /// Canonical URI string for this item (`blob:...`, `content://...`, or
  /// `file://...`).
  String get uri;

  /// Returns whether the backing resource exists and is readable.
  Future<bool> exists();

  /// Returns the byte length of the resource.
  Future<int> length();

  /// Reads the entire resource into memory as a [Uint8List].
  Future<Uint8List> readAsBytes();

  /// Reads and decodes the resource using [encoding].
  Future<String> readAsString({Encoding encoding = utf8});

  /// Streams byte chunks from [start] (inclusive) to [end] (exclusive).
  Stream<Uint8List> openRead([int? start, int? end]);

  /// Returns the last-modified timestamp of the resource.
  Future<DateTime> lastModified();

  /// Saves or downloads the resource to [targetPath].
  Future<void> saveTo(String targetPath);

  /// Writes [bytes] to the backing resource (or triggers a download on Web)
  /// and returns an updated [PlatformFileBacking] when applicable.
  Future<PlatformFileBacking?> writeAsBytes(
    Uint8List bytes, {
    required String suggestedName,
    String? mimeType,
  });
}

/// Platform-specific backing handle for non-filesystem or browser-managed
/// directories (such as Web `FileSystemDirectoryEntry` or Android SAF trees).
abstract interface class PlatformDirectoryBacking {
  /// Local filesystem path if backed by a real OS directory, or `null` for Web
  /// and Android SAF `content://` directories.
  String? get localPath;

  /// Canonical URI or virtual path representing this directory.
  String get uri;

  /// Optional updated display name resolved after access is granted.
  String? get resolvedName;

  /// Returns whether the directory exists.
  Future<bool> exists();

  /// Streams immediate child files and subdirectories on demand.
  Stream<PlatformDirectoryEntry> list();

  /// Updates the underlying URI and optional [name] in-place after scoped
  /// directory access is granted (for example on Android SAF).
  void updateGrantedAccess({required String uri, String? name});
}

/// Immediate child entry yielded while listing a directory through a platform
/// bridge.
sealed class PlatformDirectoryEntry {
  /// Creates a [PlatformDirectoryEntry].
  const PlatformDirectoryEntry({
    required this.name,
    required this.path,
    this.localPath,
  });

  /// Display name of the child file or directory.
  final String name;

  /// Path, object URL, or `content://` URI of the child entry.
  final String path;

  /// Local OS filesystem path when available, or `null` on Web / SAF.
  final String? localPath;
}

/// Immediate child file entry yielded during directory listing.
final class PlatformChildFile extends PlatformDirectoryEntry {
  /// Creates a [PlatformChildFile].
  const PlatformChildFile({
    required super.name,
    required super.path,
    super.localPath,
    this.mimeType,
    this.backing,
  });

  /// Optional MIME type reported by the platform.
  final String? mimeType;

  /// Optional platform backing handle when not backed by a local file path.
  final PlatformFileBacking? backing;
}

/// Immediate child directory entry yielded during directory listing.
final class PlatformChildDirectory extends PlatformDirectoryEntry {
  /// Creates a [PlatformChildDirectory].
  const PlatformChildDirectory({
    required super.name,
    required super.path,
    super.localPath,
    this.backing,
  });

  /// Optional platform backing handle when not backed by a local directory.
  final PlatformDirectoryBacking? backing;
}

/// Metadata and backing handle returned for a picked or dropped file.
final class PlatformPickedFileData {
  /// Creates [PlatformPickedFileData].
  const PlatformPickedFileData({
    required this.path,
    required this.name,
    this.mimeType,
    this.length,
    this.lastModified,
    this.localPath,
    this.backing,
  });

  /// Object URL, `content://` URI, or filesystem path.
  final String path;

  /// File name including extension.
  final String name;

  /// Optional MIME type reported by the platform.
  final String? mimeType;

  /// Optional known byte size.
  final int? length;

  /// Optional known last-modified timestamp.
  final DateTime? lastModified;

  /// Local OS filesystem path if available, else `null`.
  final String? localPath;

  /// Optional platform backing handle.
  final PlatformFileBacking? backing;
}

/// Hover preview metadata extracted from a browser `DataTransfer` item.
final class WebHoverItemData {
  /// Creates [WebHoverItemData].
  const WebHoverItemData({
    required this.isString,
    this.mimeType,
    this.name,
  });

  /// Whether the item kind is `'string'` rather than `'file'`.
  final bool isString;

  /// Optional MIME type advertised during hover.
  final String? mimeType;

  /// Optional item name when available.
  final String? name;
}

/// Resolved item payload delivered by a browser `drop` event.
sealed class WebDroppedItemData {
  /// Creates a [WebDroppedItemData].
  const WebDroppedItemData();
}

/// Dropped regular file resolved from a browser `drop` event.
final class WebDroppedFile extends WebDroppedItemData {
  /// Creates a [WebDroppedFile].
  const WebDroppedFile(this.file);

  /// Picked file metadata and `Blob` backing handle.
  final PlatformPickedFileData file;
}

/// Dropped directory resolved via `webkitGetAsEntry()` during a browser `drop`
/// event.
final class WebDroppedDirectory extends WebDroppedItemData {
  /// Creates a [WebDroppedDirectory].
  const WebDroppedDirectory({
    required this.name,
    required this.path,
    required this.backing,
  });

  /// Directory name.
  final String name;

  /// Virtual directory path.
  final String path;

  /// Directory reader backing handle.
  final PlatformDirectoryBacking backing;
}

/// Dropped string item resolved via `DataTransferItem.getAsString` during a
/// browser `drop` event.
final class WebDroppedString extends WebDroppedItemData {
  /// Creates a [WebDroppedString].
  const WebDroppedString({
    required this.mimeType,
    required this.value,
  });

  /// String MIME type (for example `'text/plain'` or `'text/uri-list'`).
  final String mimeType;

  /// Resolved string payload.
  final String value;
}

/// Synchronous and asynchronous hooks linking browser DOM drag events to
/// `DesktopDrop`'s hit-testing and dispatch engine.
final class WebDropCallbacks {
  /// Creates [WebDropCallbacks].
  const WebDropCallbacks({
    required this.onHover,
    required this.onLeave,
    required this.canAcceptDrop,
    required this.hasRawListeners,
    required this.onDrop,
  });

  /// Processes `dragenter` / `dragover` at `(x, y)` and returns the accepted
  /// HTML5 `dropEffect` (`'copy'`, `'move'`, `'link'`), or `null` when no
  /// enabled target accepts the drag.
  final String? Function(
    double x,
    double y,
    List<WebHoverItemData> items, {
    required bool isEnter,
  }) onHover;

  /// Processes a viewport-level `dragleave` at `(x, y)`.
  final void Function(double x, double y) onLeave;

  /// Synchronously checks whether an enabled target at `(x, y)` accepts the
  /// offered items so `event.preventDefault()` can run before any async read.
  final bool Function(double x, double y, List<WebHoverItemData> items)
      canAcceptDrop;

  /// Returns whether any raw window-level drop listeners are registered.
  final bool Function() hasRawListeners;

  /// Dispatches resolved dropped items at `(x, y)`.
  final Future<void> Function(
    double x,
    double y,
    List<WebDroppedItemData> items,
  ) onDrop;
}
