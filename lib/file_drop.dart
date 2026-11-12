/// Unified zero-dependency file selector and drag-and-drop plugin for Flutter
/// across Android, iOS, Linux, macOS, Windows, and Web/Wasm.
///
/// Exports the complete unified `file_drop` API, combining native/browser
/// open/save file and directory dialogs with multi-zone window drag-and-drop
/// targets compatible with `file_selector`, `cross_file` (`0.3.x` & `0.4.x`),
/// and `desktop_drop` (`0.8.x` & `0.9.2`).
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
export 'src/file_selector_api.dart'
    show
        clearTemporaryFiles,
        getDirectoryPath,
        getDirectoryPaths,
        getSaveLocation,
        getSavePath,
        openDirectory,
        openFile,
        openFiles,
        saveFile;
export 'src/selector_types.dart' show FileSaveLocation, XTypeGroup;
