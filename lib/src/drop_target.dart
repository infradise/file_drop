import 'dart:async';

import 'package:flutter/widgets.dart';

import 'channel.dart';
import 'drop_events.dart';

/// A widget that accepts native OS file, directory, and string drag-and-drop
/// gestures.
///
/// Supports 100% of the public APIs of both `desktop_drop 0.8.x`
/// (`onDragEntered`, `onDragUpdated`, `onDragExited`, `onDragDone`, `enable`)
/// and `desktop_drop 0.9.2` (`onDrop`, `onEnter`, `onMove`, `onLeave`,
/// `enabled`, `acceptedKinds`, `onWillAccept`, `operation`).
///
/// Multiple sibling, overlapping, or nested [DropTarget] widgets can coexist
/// in the same window. Hit-testing uses each target's laid-out [RenderBox]
/// bounds and paint order, allowing a rejecting target (`acceptedKinds` or
/// `onWillAccept` returning `false`) to fall through to underlying or ancestor
/// targets.
class DropTarget extends StatefulWidget {
  /// Creates a [DropTarget] wrapping [child].
  const DropTarget({
    super.key,
    required this.child,
    this.onDragEntered,
    this.onDragExited,
    this.onDragUpdated,
    this.onDragDone,
    this.onDrop,
    this.acceptedKinds = const <DropItemKind>{
      DropItemKind.file,
      DropItemKind.string,
      DropItemKind.directory,
    },
    this.onWillAccept,
    this.operation = DropOperation.copy,
    this.onEnter,
    this.onMove,
    this.onLeave,
    bool enable = true,
    bool? enabled,
    this.behavior = HitTestBehavior.deferToChild,
  }) : enable = enabled ?? enable;

  /// Descendant widget rendered inside this drop zone.
  final Widget child;

  /// Called when an OS drag enters this widget's bounds (`0.8.x` callback).
  final OnDragCallback<DropEventDetails>? onDragEntered;

  /// Called when an active OS drag leaves this widget's bounds or completes
  /// (`0.8.x` callback).
  final OnDragCallback<DropEventDetails>? onDragExited;

  /// Called as an active OS drag moves within this widget's bounds (`0.8.x`
  /// callback).
  final OnDragCallback<DropEventDetails>? onDragUpdated;

  /// Called when items are dropped within this widget's bounds (`0.8.x`
  /// callback).
  final OnDragDoneCallback? onDragDone;

  /// Called when items are dropped within this widget's bounds (`0.9.2`
  /// callback).
  final OnDropCallback? onDrop;

  /// Accepted item kinds (`0.9.2` filter). An empty set rejects all drags.
  final Set<DropItemKind> acceptedKinds;

  /// Optional synchronous predicate checked after [acceptedKinds].
  ///
  /// Returning `false` or throwing an exception skips this target and allows
  /// underlying or ancestor [DropTarget] widgets in the hit-test path to decide.
  final DropAcceptanceCallback? onWillAccept;

  /// Requested [DropOperation] reported for accepted drops (`0.9.2` parity).
  final DropOperation operation;

  /// Called when an accepted OS drag enters this widget's bounds (`0.9.2`
  /// callback).
  final OnDragCallback<DragDetails>? onEnter;

  /// Called as an accepted OS drag moves within this widget's bounds (`0.9.2`
  /// callback).
  final OnDragCallback<DragDetails>? onMove;

  /// Called when an accepted OS drag leaves, drops, or is disabled (`0.9.2`
  /// callback).
  final VoidCallback? onLeave;

  /// Whether this drop target actively participates in drag hit-testing.
  ///
  /// When set to `false`, drag events bypass this target completely.
  final bool enable;

  /// Alias for [enable] matching `desktop_drop 0.9.2`.
  bool get enabled => enable;

  /// Controls whether underlying or ancestor [DropTarget] widgets also receive
  /// events when overlapping (`HitTestBehavior.translucent`) or whether the
  /// front-most accepting target consumes the drag (`HitTestBehavior.deferToChild`
  /// or `HitTestBehavior.opaque`).
  final HitTestBehavior behavior;

  @override
  State<DropTarget> createState() => _DropTargetState();
}

class _DropTargetState extends State<DropTarget> implements DropTargetNode {
  @override
  bool get isEnabled => mounted && widget.enable;

  @override
  HitTestBehavior get hitTestBehavior => widget.behavior;

  @override
  Set<DropItemKind> get acceptedKinds => widget.acceptedKinds;

  @override
  DropOperation get operation => widget.operation;

  @override
  RenderBox? get renderBox {
    if (!mounted) {
      return null;
    }
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox ? renderObject : null;
  }

  @override
  void initState() {
    super.initState();
    DesktopDrop.instance.registerTarget(this);
  }

  @override
  void didUpdateWidget(DropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enable && oldWidget.enable) {
      DesktopDrop.instance.notifyTargetDisabled(this);
    }
  }

  @override
  void dispose() {
    DesktopDrop.instance.unregisterTarget(this);
    super.dispose();
  }

  @override
  bool accepts(DragDetails details) {
    return widget.onWillAccept?.call(details) ?? true;
  }

  @override
  void handleDragEntered(
    DropEventDetails eventDetails,
    DragDetails dragDetails,
  ) {
    widget.onDragEntered?.call(eventDetails);
    widget.onEnter?.call(dragDetails);
  }

  @override
  void handleDragUpdated(
    DropEventDetails eventDetails,
    DragDetails dragDetails,
  ) {
    widget.onDragUpdated?.call(eventDetails);
    widget.onMove?.call(dragDetails);
  }

  @override
  void handleDragExited(DropEventDetails eventDetails) {
    widget.onDragExited?.call(eventDetails);
    widget.onLeave?.call();
  }

  @override
  FutureOr<void> handleDragDone(
    DropDoneDetails doneDetails,
    DropDetails dropDetails,
  ) {
    widget.onDragDone?.call(doneDetails);
    return widget.onDrop?.call(dropDetails);
  }

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: this,
      behavior: widget.behavior,
      child: widget.child,
    );
  }
}
