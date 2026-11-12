import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'drop_events.dart';
import 'file_item.dart';
import 'mime_types.dart';
import 'platform/platform_bridge.dart';

/// Internal registration contract implemented by active `DropTarget` states.
abstract interface class DropTargetNode {
  /// Whether this target is currently mounted and enabled.
  bool get isEnabled;

  /// Hit-test behavior controlling whether underlying targets also receive
  /// events.
  HitTestBehavior get hitTestBehavior;

  /// Item kinds accepted by this target.
  Set<DropItemKind> get acceptedKinds;

  /// Operation reported by this target.
  DropOperation get operation;

  /// Current [RenderBox] of the target widget, if laid out.
  RenderBox? get renderBox;

  /// Evaluates `DropTarget.onWillAccept` for [details].
  bool accepts(DragDetails details);

  /// Notifies the target that a drag entered its bounds.
  void handleDragEntered(
    DropEventDetails eventDetails,
    DragDetails dragDetails,
  );

  /// Notifies the target that an active drag moved within its bounds.
  void handleDragUpdated(
    DropEventDetails eventDetails,
    DragDetails dragDetails,
  );

  /// Notifies the target that an active drag exited its bounds.
  void handleDragExited(DropEventDetails eventDetails);

  /// Notifies the target that items were dropped within its bounds.
  FutureOr<void> handleDragDone(
    DropDoneDetails doneDetails,
    DropDetails dropDetails,
  );
}

/// Window-level platform coordinator for `file_drop` across Desktop, Mobile,
/// and Web/Wasm.
///
/// Provides 100% drop-in API parity for `DesktopDrop.instance` callers across
/// both `desktop_drop 0.8.x` and `desktop_drop 0.9.2`.
class DesktopDrop {
  DesktopDrop._();

  /// Shared singleton instance.
  static final DesktopDrop instance = DesktopDrop._();

  /// Shared platform [MethodChannel] used by native selector dialogs and drag
  /// events.
  static const MethodChannel channel = MethodChannel(kFileDropChannelName);

  static const List<DropItemPreview> _incompleteFilePreview = <DropItemPreview>[
    DropItemPreview(kind: DropItemKind.file),
  ];

  final List<DropTargetNode> _targets = <DropTargetNode>[];
  final Set<DropTargetNode> _hoveredTargets = <DropTargetNode>{};
  final Set<RawDropListener> _rawListeners = <RawDropListener>{};

  Offset? _lastGlobalPosition;
  List<DropItemPreview>? _lastHoverPreviews;
  bool _lastHoverComplete = false;
  bool _handlerBound = false;

  /// Initializes incoming drag-and-drop listeners for the active platform.
  ///
  /// Attaches browser window drag listeners on Web/Wasm or binds the native
  /// [MethodChannel] handler on Desktop/Mobile. Safe to invoke multiple times.
  void init() {
    if (isWebRuntime) {
      ensureWebDropInitialized(
        WebDropCallbacks(
          onHover: _handleWebHover,
          onLeave: _handleWebLeave,
          canAcceptDrop: _canAcceptWebDrop,
          hasRawListeners: () => _rawListeners.isNotEmpty,
          onDrop: _handleWebDrop,
        ),
      );
    } else {
      channel.setMethodCallHandler(_handleNativeCall);
    }
    _handlerBound = true;
  }

  /// Registers a `DropTarget` state with the window-level dispatcher.
  void registerTarget(DropTargetNode target) {
    if (!_handlerBound || _targets.isEmpty) {
      init();
    }
    if (!_targets.contains(target)) {
      _targets.add(target);
    }
  }

  /// Unregisters a `DropTarget` state when disposed.
  void unregisterTarget(DropTargetNode target) {
    _hoveredTargets.remove(target);
    _targets.remove(target);
  }

  /// Clears hover state if [target] transitions to `enable: false` mid-drag.
  void notifyTargetDisabled(DropTargetNode target) {
    if (_hoveredTargets.remove(target)) {
      final globalPos = _lastGlobalPosition ?? Offset.zero;
      final localPos = _computeLocalPosition(target.renderBox, globalPos);
      target.handleDragExited(
        DropEventDetails(
          localPosition: localPos,
          globalPosition: globalPos,
        ),
      );
    }
  }

  /// Resets internal hover state between widget tests.
  @visibleForTesting
  void resetForTesting() {
    _hoveredTargets.clear();
    _lastGlobalPosition = null;
    _lastHoverPreviews = null;
    _lastHoverComplete = false;
  }

  /// Registers a window-level raw drag listener.
  void addRawDropEventListener(RawDropListener listener) {
    init();
    _rawListeners.add(listener);
  }

  /// Removes a previously registered window-level raw drag listener.
  void removeRawDropEventListener(RawDropListener listener) {
    _rawListeners.remove(listener);
  }

  /// Requests scoped Storage Access Framework (SAF) directory access for a
  /// dropped [directory] on Android.
  ///
  /// Invokes `'requestDirectoryAccess'` on [channel] when running on Android
  /// and returns an updated [DropDirectoryItem] (while also updating
  /// [directory] in-place for `desktop_drop 0.9.2` retry callers). Throws
  /// [UnsupportedError] on macOS, Windows, Linux, iOS, and Web.
  Future<DropDirectoryItem> requestDirectoryAccess({
    required DropItemDirectory directory,
  }) {
    if (isWebRuntime || effectiveNativePlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'Directory access requests are supported only on Android',
      );
    }
    return _requestAndroidDirectoryAccess(directory);
  }

  Future<DropDirectoryItem> _requestAndroidDirectoryAccess(
    DropItemDirectory directory,
  ) async {
    final raw = await channel.invokeMethod<Object?>(
      'requestDirectoryAccess',
      <String, dynamic>{
        'path': directory.path,
        'uri': directory.uri,
        'name': directory.name,
      },
    );
    if (raw is String && raw.isNotEmpty) {
      final grantedName =
          directory.name.isNotEmpty ? directory.name : extractPathBasename(raw);
      directory.updatePlatformDirectoryAccess(
        grantedUri: raw,
        grantedName: grantedName,
      );
      if (raw.startsWith('content://')) {
        return DropDirectoryItem.fromPlatformBacking(
          path: raw,
          name: grantedName,
          backing: createChannelDirectoryBacking(raw, name: grantedName),
        );
      }
      return DropDirectoryItem.fromPath(raw, name: grantedName);
    }
    if (raw is Map<Object?, Object?>) {
      final grantedUri =
          (raw['uri'] as String?) ?? (raw['path'] as String?) ?? directory.uri;
      final grantedName = (raw['name'] as String?) ??
          (directory.name.isNotEmpty
              ? directory.name
              : extractPathBasename(grantedUri));
      final isContent =
          (raw['isContentUri'] == true) || grantedUri.startsWith('content://');
      directory.updatePlatformDirectoryAccess(
        grantedUri: grantedUri,
        grantedName: grantedName,
      );
      if (isContent) {
        return DropDirectoryItem.fromPlatformBacking(
          path: grantedUri,
          name: grantedName,
          backing: createChannelDirectoryBacking(
            grantedUri,
            name: grantedName,
          ),
        );
      }
      return DropDirectoryItem.fromPath(grantedUri, name: grantedName);
    }
    if (directory is DropDirectoryItem) {
      return directory;
    }
    return DropDirectoryItem(
      directory: directory,
      name: directory.name,
      localPath: directory.localPath,
    );
  }

  /// Starts Apple (`macOS` / `iOS`) security-scoped access for a bookmarked
  /// dropped resource.
  ///
  /// Returns `false` immediately when [bookmark] is empty or on non-Apple
  /// platforms where security-scoped bookmarks are not used.
  Future<bool> startAccessingSecurityScopedResource({
    required Uint8List bookmark,
  }) async {
    if (bookmark.isEmpty || isWebRuntime) {
      return false;
    }
    final result = await channel.invokeMethod<bool>(
      'startAccessingSecurityScopedResource',
      <String, dynamic>{
        'appleBookmark': bookmark,
        'apple-bookmark': bookmark,
      },
    );
    return result ?? false;
  }

  /// Stops Apple (`macOS` / `iOS`) security-scoped access previously started
  /// with [bookmark].
  Future<bool> stopAccessingSecurityScopedResource({
    required Uint8List bookmark,
  }) async {
    if (bookmark.isEmpty || isWebRuntime) {
      return true;
    }
    final result = await channel.invokeMethod<bool>(
      'stopAccessingSecurityScopedResource',
      <String, dynamic>{
        'appleBookmark': bookmark,
        'apple-bookmark': bookmark,
      },
    );
    return result ?? true;
  }

  String? _handleWebHover(
    double x,
    double y,
    List<WebHoverItemData> hoverItems, {
    required bool isEnter,
  }) {
    final globalPos = Offset(x, y);
    final previews = _previewsFromWebHover(hoverItems);
    _lastGlobalPosition = globalPos;
    _lastHoverPreviews = previews;
    _lastHoverComplete = false;
    if (isEnter) {
      _notifyRawListeners(DropEnterEvent(location: globalPos));
    } else {
      _notifyRawListeners(DropUpdateEvent(location: globalPos));
    }
    final hits = _dispatchHover(
      globalPos,
      previews: previews,
      isComplete: false,
    );
    if (hits.isEmpty) {
      return null;
    }
    return hits.first.target.operation.name;
  }

  void _handleWebLeave(double x, double y) {
    final globalPos = Offset(x, y);
    _lastGlobalPosition = null;
    _lastHoverPreviews = null;
    _lastHoverComplete = false;
    _notifyRawListeners(DropExitEvent(location: globalPos));
    _dispatchExitAll(globalPos);
  }

  bool _canAcceptWebDrop(
    double x,
    double y,
    List<WebHoverItemData> hoverItems,
  ) {
    final globalPos = Offset(x, y);
    final previews = _previewsFromWebHover(hoverItems);
    final hits = _hitTestTargets(
      globalPos,
      previews: previews,
      isComplete: false,
    );
    return hits.isNotEmpty;
  }

  Future<void> _handleWebDrop(
    double x,
    double y,
    List<WebDroppedItemData> webItems,
  ) async {
    final globalPos = Offset(x, y);
    final items = <DropItem>[];
    String? rawText;
    for (final entry in webItems) {
      switch (entry) {
        case WebDroppedFile(:final file):
          items.add(DropFileItem.fromPlatformData(file));
        case WebDroppedDirectory(:final name, :final path, :final backing):
          items.add(
            DropDirectoryItem.fromPlatformBacking(
              path: path,
              name: name,
              backing: backing,
            ),
          );
        case WebDroppedString(:final mimeType, :final value):
          if (mimeType == 'text/uri-list' && rawText == null) {
            rawText = value;
          }
          items.add(DropStringItem(mimeType: mimeType, value: value));
      }
    }
    _lastGlobalPosition = null;
    _lastHoverPreviews = null;
    _lastHoverComplete = false;
    _notifyRawListeners(
      DropDoneEvent(
        location: globalPos,
        files: items,
        rawText: rawText,
      ),
    );
    await _dispatchDrop(globalPos, items, rawText);
  }

  static List<DropItemPreview> _previewsFromWebHover(
    List<WebHoverItemData> hoverItems,
  ) {
    if (hoverItems.isEmpty) {
      return _incompleteFilePreview;
    }
    return hoverItems
        .map(
          (WebHoverItemData item) => DropItemPreview(
            kind: item.isString ? DropItemKind.string : DropItemKind.file,
            mimeType: item.mimeType,
            name: item.name,
          ),
        )
        .toList(growable: false);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDragEntered':
      case 'entered':
        final globalPos = _parseOffset(call.arguments) ?? Offset.zero;
        final hoverOffer = _parseHoverOffer(call.arguments);
        _lastGlobalPosition = globalPos;
        _lastHoverPreviews = hoverOffer.$1;
        _lastHoverComplete = hoverOffer.$2;
        _notifyRawListeners(DropEnterEvent(location: globalPos));
        _dispatchHover(
          globalPos,
          previews: hoverOffer.$1,
          isComplete: hoverOffer.$2,
        );
      case 'onDragUpdated':
      case 'updated':
        final globalPos =
            _parseOffset(call.arguments) ?? _lastGlobalPosition ?? Offset.zero;
        final hoverOffer = _parseHoverOffer(
          call.arguments,
          fallbackPreviews: _lastHoverPreviews,
          fallbackComplete: _lastHoverComplete,
        );
        _lastGlobalPosition = globalPos;
        _lastHoverPreviews = hoverOffer.$1;
        _lastHoverComplete = hoverOffer.$2;
        _notifyRawListeners(DropUpdateEvent(location: globalPos));
        _dispatchHover(
          globalPos,
          previews: hoverOffer.$1,
          isComplete: hoverOffer.$2,
        );
      case 'onDragExited':
      case 'exited':
        final globalPos =
            _parseOffset(call.arguments) ?? _lastGlobalPosition ?? Offset.zero;
        _lastGlobalPosition = null;
        _lastHoverPreviews = null;
        _lastHoverComplete = false;
        _notifyRawListeners(DropExitEvent(location: globalPos));
        _dispatchExitAll(globalPos);
      case 'onDragDone':
      case 'performOperation':
        final globalPos =
            _parseOffset(call.arguments) ?? _lastGlobalPosition ?? Offset.zero;
        final rawText = _parseRawText(call.arguments);
        final sessionId = _parseSessionId(call.arguments);
        final items = _parseDropItems(call.arguments);
        _lastGlobalPosition = null;
        _lastHoverPreviews = null;
        _lastHoverComplete = false;
        try {
          _notifyRawListeners(
            DropDoneEvent(
              location: globalPos,
              files: items,
              rawText: rawText,
            ),
          );
          await _dispatchDrop(globalPos, items, rawText);
        } finally {
          if (sessionId != null && sessionId.isNotEmpty) {
            try {
              await channel.invokeMethod<void>(
                'releaseDropSession',
                <String, dynamic>{'sessionId': sessionId},
              );
            } on MissingPluginException {
              // Ignore when host platform does not implement session cleanup.
            }
          }
        }
      default:
        throw MissingPluginException('Unhandled method ${call.method}');
    }
    return null;
  }

  void _notifyRawListeners(DropEvent event) {
    for (final listener in List<RawDropListener>.of(_rawListeners)) {
      listener(event);
    }
  }

  List<_TargetHit> _dispatchHover(
    Offset globalPosition, {
    required List<DropItemPreview> previews,
    required bool isComplete,
  }) {
    final hits = _hitTestTargets(
      globalPosition,
      previews: previews,
      isComplete: isComplete,
    );
    final nextHovered = hits.map((_TargetHit h) => h.target).toSet();

    // 1. Fire exit callbacks first on any previously hovered target no longer hit.
    final exited = _hoveredTargets.difference(nextHovered).toList();
    for (final target in exited) {
      _hoveredTargets.remove(target);
      if (!target.isEnabled) {
        continue;
      }
      final localPos = _computeLocalPosition(target.renderBox, globalPosition);
      target.handleDragExited(
        DropEventDetails(
          localPosition: localPos,
          globalPosition: globalPosition,
        ),
      );
    }

    // 2. Fire enter or update callbacks on current hit targets.
    for (final hit in hits) {
      final eventDetails = DropEventDetails(
        localPosition: hit.localPosition,
        globalPosition: globalPosition,
      );
      if (_hoveredTargets.add(hit.target)) {
        hit.target.handleDragEntered(eventDetails, hit.dragDetails);
      } else {
        hit.target.handleDragUpdated(eventDetails, hit.dragDetails);
      }
    }
    return hits;
  }

  void _dispatchExitAll(Offset globalPosition) {
    final active = List<DropTargetNode>.of(_hoveredTargets);
    _hoveredTargets.clear();
    for (final target in active) {
      if (!target.isEnabled) {
        continue;
      }
      final localPos = _computeLocalPosition(target.renderBox, globalPosition);
      target.handleDragExited(
        DropEventDetails(
          localPosition: localPos,
          globalPosition: globalPosition,
        ),
      );
    }
  }

  Future<void> _dispatchDrop(
    Offset globalPosition,
    List<DropItem> items,
    String? rawText,
  ) async {
    final previews = _previewsFromDropItems(items);
    final hits = _hitTestTargets(
      globalPosition,
      previews: previews,
      isComplete: true,
    );

    // Exit any hovered targets before completing the drop so hover highlights
    // always reset cleanly across all platforms.
    if (_hoveredTargets.isNotEmpty) {
      _dispatchExitAll(globalPosition);
    }

    final unmodifiableItems = List<DropItem>.unmodifiable(items);
    for (final hit in hits) {
      final doneDetails = DropDoneDetails(
        files: unmodifiableItems,
        localPosition: hit.localPosition,
        globalPosition: globalPosition,
        rawText: rawText,
      );
      final dropDetails = DropDetails(
        items: unmodifiableItems,
        localPosition: hit.localPosition,
        globalPosition: globalPosition,
        operation: hit.target.operation,
        rawText: rawText,
      );
      try {
        await hit.target.handleDragDone(doneDetails, dropDetails);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'file_drop',
            context: ErrorDescription('in DropTarget drop callback'),
          ),
        );
      }
    }
  }

  List<_TargetHit> _hitTestTargets(
    Offset globalPosition, {
    required List<DropItemPreview> previews,
    required bool isComplete,
  }) {
    final candidates = <_TargetCandidate>[];
    for (final target in List<DropTargetNode>.of(_targets)) {
      if (!target.isEnabled) {
        continue;
      }
      final box = target.renderBox;
      if (box == null || !box.attached || !box.hasSize) {
        continue;
      }
      final localPos = box.globalToLocal(globalPosition);
      if (box.paintBounds.contains(localPos)) {
        candidates.add(
          _TargetCandidate(
            target: target,
            box: box,
            localPosition: localPos,
          ),
        );
      }
    }

    if (candidates.isEmpty) {
      return const <_TargetHit>[];
    }

    candidates.sort(
      (_TargetCandidate a, _TargetCandidate b) =>
          _compareRenderBoxesFrontToBack(a.box, b.box),
    );

    final winners = <_TargetHit>[];
    for (final candidate in candidates) {
      final target = candidate.target;
      if (!_matchesAcceptedKinds(target.acceptedKinds, previews, isComplete)) {
        continue;
      }

      final dragDetails = DragDetails(
        items: previews,
        localPosition: candidate.localPosition,
        globalPosition: globalPosition,
      );

      var accepted = false;
      try {
        accepted = target.accepts(dragDetails);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'file_drop',
            context: ErrorDescription('in DropTarget.onWillAccept'),
          ),
        );
      }
      if (!accepted) {
        continue;
      }

      winners.add(
        _TargetHit(
          target: target,
          localPosition: candidate.localPosition,
          dragDetails: dragDetails,
        ),
      );
      if (target.hitTestBehavior != HitTestBehavior.translucent) {
        break;
      }
    }
    return winners;
  }

  static bool _matchesAcceptedKinds(
    Set<DropItemKind> acceptedKinds,
    List<DropItemPreview> previews,
    bool isComplete,
  ) {
    if (acceptedKinds.isEmpty) {
      return false;
    }
    if (previews.isEmpty) {
      return !isComplete;
    }
    return previews.any(
      (DropItemPreview item) =>
          acceptedKinds.contains(item.kind) ||
          (!isComplete &&
              item.kind == DropItemKind.file &&
              acceptedKinds.contains(DropItemKind.directory)),
    );
  }

  static List<DropItemPreview> _previewsFromDropItems(List<DropItem> items) {
    return items.map((DropItem item) {
      if (item is DropStringItem) {
        return DropItemPreview(
          kind: DropItemKind.string,
          mimeType: item.mimeType,
          value: item.value,
        );
      }
      if (item is DropItemDirectory || item.isDirectory) {
        return DropItemPreview(
          kind: DropItemKind.directory,
          name: item.name,
          localPath: item.localPath,
          isPromised: item.isPromised,
        );
      }
      return DropItemPreview(
        kind: DropItemKind.file,
        name: item.name,
        localPath: item.localPath,
        mimeType: item.mimeType,
        isPromised: item.isPromised,
      );
    }).toList(growable: false);
  }

  static (List<DropItemPreview>, bool) _parseHoverOffer(
    Object? raw, {
    List<DropItemPreview>? fallbackPreviews,
    bool fallbackComplete = false,
  }) {
    if (raw is Map<Object?, Object?>) {
      final offerMap = raw['offer'];
      if (offerMap is Map<Object?, Object?>) {
        final offer = DropOffer.fromMap(offerMap);
        return (offer.items, offer.isComplete);
      }
      if (raw.containsKey('items') ||
          raw.containsKey('files') ||
          raw.containsKey('strings')) {
        final offer = DropOffer.fromMap(raw);
        return (offer.items, offer.isComplete);
      }
    }
    if (fallbackPreviews != null) {
      return (fallbackPreviews, fallbackComplete);
    }
    return (_incompleteFilePreview, false);
  }

  static Offset _computeLocalPosition(RenderBox? box, Offset globalPosition) {
    if (box == null || !box.attached || !box.hasSize) {
      return Offset.zero;
    }
    return box.globalToLocal(globalPosition);
  }

  static int _compareRenderBoxesFrontToBack(RenderBox a, RenderBox b) {
    if (identical(a, b)) {
      return 0;
    }
    final chainA = _buildAncestorChain(a);
    final chainB = _buildAncestorChain(b);

    // Deeper nested RenderBox is painted in front of its ancestor.
    if (chainA.contains(b)) {
      return -1;
    }
    if (chainB.contains(a)) {
      return 1;
    }

    // Walk from the root down to the lowest common ancestor.
    var idxA = chainA.length - 1;
    var idxB = chainB.length - 1;
    if (!identical(chainA[idxA], chainB[idxB])) {
      return 0;
    }
    while (
        idxA > 0 && idxB > 0 && identical(chainA[idxA - 1], chainB[idxB - 1])) {
      idxA--;
      idxB--;
    }

    final commonAncestor = chainA[idxA];
    final branchA = chainA[idxA - 1];
    final branchB = chainB[idxB - 1];

    var order = 0;
    var index = 0;
    var orderA = -1;
    var orderB = -1;
    commonAncestor.visitChildren((RenderObject child) {
      if (identical(child, branchA)) {
        orderA = index;
      } else if (identical(child, branchB)) {
        orderB = index;
      }
      index++;
    });

    if (orderA != -1 && orderB != -1) {
      // RenderObject.visitChildren visits in paint order (back-to-front).
      // Higher index means painted later (closer to front).
      order = orderB.compareTo(orderA);
    }
    return order;
  }

  static List<RenderObject> _buildAncestorChain(RenderObject leaf) {
    final chain = <RenderObject>[leaf];
    var current = leaf.parent;
    while (current != null) {
      chain.add(current);
      current = current.parent;
    }
    return chain;
  }

  static Offset? _parseOffset(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      final x = raw['x'];
      final y = raw['y'];
      if (x is num && y is num) {
        return Offset(x.toDouble(), y.toDouble());
      }
    } else if (raw is List<Object?> && raw.length >= 2) {
      final x = raw[0];
      final y = raw[1];
      if (x is num && y is num) {
        return Offset(x.toDouble(), y.toDouble());
      }
    }
    return null;
  }

  static String? _parseRawText(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      final value = raw['rawText'];
      if (value is String) {
        return value;
      }
    }
    return null;
  }

  static String? _parseSessionId(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      final value = raw['sessionId'];
      if (value is String) {
        return value;
      }
    }
    return null;
  }

  static List<DropItem> _parseDropItems(Object? raw) {
    final result = <DropItem>[];

    var rawItems = raw;
    Object? rawStrings;
    if (raw is Map<Object?, Object?>) {
      rawItems = raw['items'] ?? raw['files'];
      rawStrings = raw['strings'];
    }

    if (rawItems is List<Object?>) {
      for (final entry in rawItems) {
        if (entry is String) {
          if (entry.isEmpty) {
            continue;
          }
          if (entry.startsWith('content://')) {
            final name = extractPathBasename(entry);
            result.add(
              DropFileItem.fromPlatformData(
                PlatformPickedFileData(
                  path: entry,
                  name: name,
                  localPath: null,
                  backing: createChannelFileBacking(entry),
                ),
              ),
            );
            continue;
          }
          final isDir = platformIsDirectorySync(entry);
          result.add(
            isDir
                ? DropDirectoryItem.fromPath(entry)
                : DropFileItem.fromPath(entry),
          );
        } else if (entry is Map<Object?, Object?>) {
          if (entry['kind'] == 'string' ||
              (!entry.containsKey('path') &&
                  !entry.containsKey('uri') &&
                  entry['value'] is String)) {
            result.add(
              DropStringItem(
                mimeType: (entry['mimeType'] as String?) ?? 'text/plain',
                value: entry['value'] as String,
              ),
            );
            continue;
          }
          final rawPath =
              (entry['path'] as String?) ?? (entry['uri'] as String?) ?? '';
          final rawUri = (entry['uri'] as String?) ?? rawPath;
          if (rawPath.isEmpty && rawUri.isEmpty) {
            continue;
          }
          final isContentUri = (entry['isContentUri'] == true) ||
              rawUri.startsWith('content://') ||
              rawPath.startsWith('content://');
          final isDirFlag = entry['isDirectory'];
          final isDir = isDirFlag is bool
              ? isDirFlag
              : (!isContentUri && platformIsDirectorySync(rawPath));
          final bookmarkRaw = entry['appleBookmark'] ?? entry['apple-bookmark'];
          final bookmark = bookmarkRaw is Uint8List ? bookmarkRaw : null;
          final fromPromise = (entry['isPromised'] as bool?) ??
              (entry['fromPromise'] as bool?) ??
              false;
          final mimeType = entry['mimeType'] as String?;
          final name = entry['name'] as String?;

          if (isContentUri) {
            final effectiveName = name ??
                extractPathBasename(rawPath.isNotEmpty ? rawPath : rawUri);
            if (isDir) {
              result.add(
                DropDirectoryItem.fromPlatformBacking(
                  path: rawUri,
                  name: effectiveName,
                  backing: createChannelDirectoryBacking(
                    rawUri,
                    name: effectiveName,
                  ),
                  appleBookmark: bookmark,
                  isPromised: fromPromise,
                ),
              );
            } else {
              result.add(
                DropFileItem.fromPlatformData(
                  PlatformPickedFileData(
                    path: rawUri,
                    name: effectiveName,
                    mimeType: mimeType,
                    localPath: null,
                    backing: createChannelFileBacking(rawUri),
                  ),
                  appleBookmark: bookmark,
                  isPromised: fromPromise,
                ),
              );
            }
          } else if (isDir) {
            result.add(
              DropDirectoryItem.fromPath(
                rawPath,
                name: name,
                appleBookmark: bookmark,
                isPromised: fromPromise,
              ),
            );
          } else {
            result.add(
              DropFileItem.fromPath(
                rawPath,
                name: name,
                mimeType: mimeType,
                appleBookmark: bookmark,
                isPromised: fromPromise,
              ),
            );
          }
        }
      }
    }

    if (rawStrings is List<Object?>) {
      for (final entry in rawStrings) {
        if (entry is Map<Object?, Object?> && entry['value'] is String) {
          result.add(
            DropStringItem(
              mimeType: (entry['mimeType'] as String?) ?? 'text/plain',
              value: entry['value'] as String,
            ),
          );
        }
      }
    }

    return result;
  }
}

class _TargetCandidate {
  const _TargetCandidate({
    required this.target,
    required this.box,
    required this.localPosition,
  });

  final DropTargetNode target;
  final RenderBox box;
  final Offset localPosition;
}

class _TargetHit {
  const _TargetHit({
    required this.target,
    required this.localPosition,
    required this.dragDetails,
  });

  final DropTargetNode target;
  final Offset localPosition;
  final DragDetails dragDetails;
}
