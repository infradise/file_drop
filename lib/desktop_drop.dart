/// Drop-in compatibility barrel for `package:desktop_drop/desktop_drop.dart`
/// (`0.8.x` and `0.9.2`).
///
/// Migrate existing callers by changing only the package name in imports:
///
/// ```dart
/// import 'package:file_drop/desktop_drop.dart';
/// ```
library;

export 'src/channel.dart' show DesktopDrop;
export 'src/drop_events.dart'
    show
        DragDetails,
        DropAcceptanceCallback,
        DropDetails,
        DropDoneDetails,
        DropDoneEvent,
        DropEnterEvent,
        DropEvent,
        DropEventDetails,
        DropExitEvent,
        DropItemKind,
        DropItemPreview,
        DropOffer,
        DropOperation,
        DropUpdateEvent,
        OnDragCallback,
        OnDragDoneCallback,
        OnDropCallback,
        RawDropListener;
export 'src/drop_target.dart' show DropTarget;
export 'src/file_item.dart'
    show
        DropDirectoryItem,
        DropFileItem,
        DropItem,
        DropItemDirectory,
        DropItemFile,
        DropStringItem,
        FileDropItem,
        FileSystemXDirectory,
        FileSystemXFile,
        XDirectory,
        XEntity,
        XFile;
