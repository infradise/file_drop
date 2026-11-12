import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart' show Offset;

import 'file_item.dart';

/// Broad item kinds available to synchronous drag acceptance checks
/// (`desktop_drop 0.9.2` parity).
enum DropItemKind {
  /// A regular or virtual file item.
  file,

  /// A text or URI string representation.
  string,

  /// A filesystem directory item.
  directory,
}

/// Drag-and-drop operation requested by a `DropTarget` (`desktop_drop 0.9.2`
/// parity).
enum DropOperation {
  /// Copy dropped data without modifying the source.
  copy,

  /// Move dropped data from the source.
  move,

  /// Create a link or alias to the source data.
  link,
}

/// Metadata visible synchronously while deciding whether to accept or while
/// hovering (`desktop_drop 0.9.2` parity).
@immutable
class DropItemPreview {
  /// Creates a [DropItemPreview] describing an offered drag item.
  const DropItemPreview({
    required this.kind,
    String? mimeType,
    this.name,
    this.localPath,
    this.value,
    this.isPromised = false,
  }) : _mimeType = mimeType;

  /// Broad kind of the offered item.
  final DropItemKind kind;

  final String? _mimeType;

  /// Reported MIME type, falling back to filename extension inference for
  /// [DropItemKind.file] when omitted.
  String? get mimeType => kind == DropItemKind.file
      ? inferMimeTypeFromPath(_mimeType, name, localPath)
      : _mimeType;

  /// Optional filename or directory name advertised during hover.
  final String? name;

  /// Optional local filesystem path advertised during hover.
  final String? localPath;

  /// Optional string payload when available during hover.
  final String? value;

  /// Whether the item is backed by a native file promise.
  final bool isPromised;

  @override
  String toString() =>
      'DropItemPreview(kind: $kind, name: $name, localPath: $localPath, mimeType: $mimeType)';
}

/// Synchronous drag offer metadata inspected during target selection
/// (`desktop_drop 0.9.2` parity).
@immutable
class DropOffer {
  /// Creates an unmodifiable [DropOffer].
  DropOffer({
    required List<DropItemPreview> items,
    this.isComplete = true,
    Set<DropOperation> allowedOperations = const <DropOperation>{
      DropOperation.copy,
    },
  })  : items = List<DropItemPreview>.unmodifiable(items),
        allowedOperations = Set<DropOperation>.unmodifiable(allowedOperations);

  /// Deserializes a [DropOffer] from a native platform map.
  factory DropOffer.fromMap(Map<Object?, Object?> map) {
    final rawFiles = map['files'] ?? map['items'];
    final rawStrings = map['strings'];
    final previews = <DropItemPreview>[];

    if (rawFiles is List<Object?>) {
      for (final entry in rawFiles) {
        if (entry is Map<Object?, Object?>) {
          previews.add(
            DropItemPreview(
              kind: entry['isDirectory'] == true
                  ? DropItemKind.directory
                  : DropItemKind.file,
              name: entry['name'] as String?,
              localPath: entry['path'] as String?,
              mimeType: entry['mimeType'] as String?,
              isPromised: (entry['isPromised'] as bool?) ??
                  (entry['fromPromise'] as bool?) ??
                  false,
            ),
          );
        }
      }
    }

    if (rawStrings is List<Object?>) {
      for (final entry in rawStrings) {
        if (entry is Map<Object?, Object?>) {
          previews.add(
            DropItemPreview(
              kind: DropItemKind.string,
              mimeType: (entry['mimeType'] as String?) ?? 'text/plain',
              value: entry['value'] as String?,
            ),
          );
        }
      }
    }

    final rawAllowed = map['allowedOperations'];
    final allowed = rawAllowed is List<Object?>
        ? DropOperation.values
            .where((DropOperation op) => rawAllowed.contains(op.name))
            .toSet()
        : const <DropOperation>{DropOperation.copy};

    return DropOffer(
      items: previews,
      isComplete: (map['isComplete'] as bool?) ?? true,
      allowedOperations:
          allowed.isEmpty ? const <DropOperation>{DropOperation.copy} : allowed,
    );
  }

  /// Preview representations offered by the drag source.
  final List<DropItemPreview> items;

  /// Whether all item kinds and paths are already resolved during hover.
  final bool isComplete;

  /// Operations permitted by the drag source.
  final Set<DropOperation> allowedOperations;
}

/// Hover and acceptance details delivered to `DropTarget.onWillAccept`,
/// `DropTarget.onEnter`, and `DropTarget.onMove` (`desktop_drop 0.9.2` parity).
@immutable
class DragDetails {
  /// Creates [DragDetails] with preview [items] and cursor positions.
  DragDetails({
    required List<DropItemPreview> items,
    required this.localPosition,
    required this.globalPosition,
  }) : items = List<DropItemPreview>.unmodifiable(items);

  /// Offered item previews for the active drag.
  final List<DropItemPreview> items;

  /// Cursor position in the receiving `DropTarget` widget's local coordinate
  /// space.
  final Offset localPosition;

  /// Cursor position in the Flutter view's top-left logical coordinate space.
  final Offset globalPosition;

  @override
  String toString() =>
      'DragDetails(items: $items, localPosition: $localPosition, globalPosition: $globalPosition)';
}

/// Payload delivered to `DropTarget.onDrop` (`desktop_drop 0.9.2` parity).
@immutable
class DropDetails {
  /// Creates [DropDetails] containing dropped [items], positions, and
  /// [operation].
  DropDetails({
    required List<DropItem> items,
    required this.localPosition,
    required this.globalPosition,
    this.operation = DropOperation.copy,
    this.rawText,
  }) : items = List<DropItem>.unmodifiable(items);

  /// Dropped items (`DropFileItem`, `DropDirectoryItem`, or `DropStringItem`).
  final List<DropItem> items;

  /// Alias for [items] matching `DropDoneDetails.files`.
  List<DropItem> get files => items;

  /// Drop position in the receiving `DropTarget` widget's local coordinate
  /// space.
  final Offset localPosition;

  /// Drop position in the Flutter view's top-left logical coordinate space.
  final Offset globalPosition;

  /// Negotiated [DropOperation] for this drop.
  final DropOperation operation;

  /// Optional raw URI list payload supplied by the native drag source.
  final String? rawText;

  @override
  String toString() =>
      'DropDetails(items: $items, localPosition: $localPosition, globalPosition: $globalPosition, operation: $operation)';
}

/// Position details delivered to `DropTarget` hover callbacks
/// (`desktop_drop 0.8.x` parity).
@immutable
class DropEventDetails {
  /// Creates [DropEventDetails] with widget-local and window-global positions.
  const DropEventDetails({
    required this.localPosition,
    required this.globalPosition,
  });

  /// Cursor position in the receiving `DropTarget` widget's local coordinate
  /// space.
  final Offset localPosition;

  /// Cursor position in the Flutter view's top-left logical coordinate space.
  final Offset globalPosition;

  @override
  String toString() =>
      'DropEventDetails(localPosition: $localPosition, globalPosition: $globalPosition)';
}

/// Payload delivered to `DropTarget.onDragDone` when files or directories are
/// dropped onto an active target (`desktop_drop 0.8.x` parity).
@immutable
class DropDoneDetails {
  /// Creates [DropDoneDetails] containing dropped [files] and cursor positions.
  const DropDoneDetails({
    required this.files,
    required this.localPosition,
    required this.globalPosition,
    this.rawText,
  });

  /// Dropped files and directories (`DropItemFile` or `DropItemDirectory`).
  final List<DropItem> files;

  /// Alias for [files] matching `DropDetails.items` in `desktop_drop 0.9.2`.
  List<DropItem> get items => files;

  /// Drop position in the receiving `DropTarget` widget's local coordinate
  /// space.
  final Offset localPosition;

  /// Drop position in the Flutter view's top-left logical coordinate space.
  final Offset globalPosition;

  /// Optional raw URI list text supplied by the native drag source (for
  /// example, `text/uri-list` on Linux).
  final String? rawText;

  @override
  String toString() =>
      'DropDoneDetails(files: $files, localPosition: $localPosition, globalPosition: $globalPosition)';
}

/// Signature for receiving completed drop operations via `onDragDone`
/// (`desktop_drop 0.8.x` parity).
typedef OnDragDoneCallback = void Function(DropDoneDetails details);

/// Signature for receiving completed drop operations via `onDrop`
/// (`desktop_drop 0.9.2` parity).
typedef OnDropCallback = FutureOr<void> Function(DropDetails details);

/// Signature for synchronous drag acceptance predicates via `onWillAccept`
/// (`desktop_drop 0.9.2` parity).
typedef DropAcceptanceCallback = bool Function(DragDetails details);

/// Signature for receiving drag hover lifecycle callbacks on a `DropTarget`.
typedef OnDragCallback<Detail> = void Function(Detail details);

/// Base raw window-level drag event for `DesktopDrop` raw listeners.
@immutable
abstract class DropEvent {
  /// Creates a [DropEvent] at [location].
  const DropEvent(this.location);

  /// Window-level logical cursor location of the event.
  final Offset location;

  @override
  String toString() => '$runtimeType($location)';
}

/// Window-level raw event emitted when a native drag enters the window.
class DropEnterEvent extends DropEvent {
  /// Creates a [DropEnterEvent] at [location].
  const DropEnterEvent({required Offset location}) : super(location);
}

/// Window-level raw event emitted when a native drag moves inside the window.
class DropUpdateEvent extends DropEvent {
  /// Creates a [DropUpdateEvent] at [location].
  const DropUpdateEvent({required Offset location}) : super(location);
}

/// Window-level raw event emitted when a native drag leaves the window.
class DropExitEvent extends DropEvent {
  /// Creates a [DropExitEvent] at [location].
  const DropExitEvent({required Offset location}) : super(location);
}

/// Window-level raw event emitted when items are dropped onto the window.
class DropDoneEvent extends DropEvent {
  /// Creates a [DropDoneEvent] at [location] with [files] and optional
  /// [rawText].
  const DropDoneEvent({
    required Offset location,
    required this.files,
    this.rawText,
  }) : super(location);

  /// Dropped files and directories.
  final List<DropItem> files;

  /// Optional raw URI list payload.
  final String? rawText;
}

/// Callback signature for window-level raw drag listeners on `DesktopDrop`.
typedef RawDropListener = void Function(DropEvent event);
