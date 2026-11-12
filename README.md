# file_drop

[![Pub Version](https://img.shields.io/pub/v/file_drop)](https://pub.dev/packages/file_drop)
[![Dependencies](https://img.shields.io/badge/dependencies-zero-brightgreen)](https://pub.dev/packages/file_drop)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/infradise/file_drop/blob/main/LICENSE)

Zero-dependency file selector and drag-and-drop plugin for Flutter across **Android**, **iOS**, **Linux**, **macOS**, **Windows**, and **Web / WebAssembly**.

`file_drop` unifies and replaces [`file_selector`](https://pub.dev/packages/file_selector), [`cross_file`](https://pub.dev/packages/cross_file) (`0.3.x` & `0.4.x`), and [`desktop_drop`](https://pub.dev/packages/desktop_drop) (`0.8.x` & `0.9.2`) in a single self-contained plugin with **zero external hosted dependencies**.

## Why `file_drop` Exists

Adding both `file_selector` and `desktop_drop` to a Flutter project pulls in a conflicting transitive dependency graph that frequently breaks `pub get` version solving:

- `file_selector` pulls in **7 federated packages** (`file_selector_platform_interface`, `file_selector_android`, `file_selector_ios`, `file_selector_linux`, `file_selector_macos`, `file_selector_windows`, `file_selector_web`) and pins `cross_file ^0.3.0`.
- `desktop_drop` (`>=0.9.0`) requires `cross_file ^0.4.0` (which adds 5 federated `cross_file_*` packages) alongside `mime` and `web` (while `0.8.x` depended on `universal_platform`, `dbus`, and `ffi`), causing an unresolvable `cross_file` major-version conflict whenever installed alongside `file_selector`.

`file_drop` eliminates **every** external Pub, CocoaPods/SPM, CMake, and Gradle/Maven dependency (`dependencies` contains **only** Flutter SDK packages: `flutter` and `flutter_web_plugins`):

- **Android (`Kotlin` + Storage Access Framework + `View.OnDragListener`, minSdk 24)**: Zero-`androidx` SAF document/tree pickers (`ACTION_OPEN_DOCUMENT`, `ACTION_CREATE_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`), chunked `ContentResolver` streaming, multi-window `View.OnDragListener` + `DragAndDropPermissions`, and `DocumentsContract` directory traversal (`requestDirectoryAccess`).
- **iOS (`Swift` + `UIKit` + `UniformTypeIdentifiers`, iOS 14.0+)**: Dual Swift Package Manager + CocoaPods layout with `PrivacyInfo.xcprivacy`, `UIDocumentPickerViewController` open/export/folder dialogs, `NSFileCoordinator` staging, security-scoped bookmarks, and iOS/iPadOS `UIDropInteraction` drag-and-drop.
- **Linux (`C++` + `GTK3` + XDG Desktop Portal)**: Asynchronous `GtkFileChooserNative` dialogs automatically backed by `org.freedesktop.portal.FileChooser` (zero Dart `dbus` dependencies) and `gtk_drag_dest_set` (`text/uri-list` + text drops across X11 and Wayland).
- **macOS (`Swift` + `AppKit` + `UniformTypeIdentifiers`, macOS 11.0+)**: Dual Swift Package Manager + CocoaPods layout with `PrivacyInfo.xcprivacy`, sheet/modal `NSOpenPanel` and `NSSavePanel` dialogs, `UTType` content filtering, `NSFilePromiseReceiver` promised files, security-scoped bookmarks, and a resize-safe non-intercepting `NSDraggingDestination` view.
- **Windows (`C++` + `Win32 COM` + OLE `IDropTarget`)**: Native `IFileOpenDialog` and `IFileSaveDialog` COM dialogs plus `OleInitialize` + `IDropTarget` / `IDropTargetHelper` drag-and-drop with per-monitor HiDPI scaling (`FlutterDesktopGetDpiForHWND`).
- **Web / WebAssembly (`dart:js_interop`, `dart2wasm`-ready)**: Pure `dart:js_interop` implementation (zero `package:web` or `dart:html`) using off-screen `<input type="file">`, File System Access API (`showSaveFilePicker`) with `<a download>` `Blob` fallback, `DataTransfer` + `webkitGetAsEntry` recursive directory drops, and 256 KB `Blob.slice` streaming.

## Compatibility Chart

| API | Android | iOS | Linux | macOS | Windows | Web |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `openFile()` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `openFiles()` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `saveFile()` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `getSaveLocation()` / `getSavePath()` | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| `openDirectory()` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `getDirectoryPath()` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `getDirectoryPaths()` | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `clearTemporaryFiles()` | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| `DropTarget` (files, text, URIs) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `DropTarget` (directories) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `XFile` (`readAsBytes`, `openRead`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `requestDirectoryAccess()` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `startAccessingSecurityScopedResource()` | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ |

- **`saveFile(bytes: ...)` vs `getSaveLocation()`**: `saveFile(bytes: ...)` works across all **6 platforms** by writing bytes directly through native/browser export flows. `getSaveLocation()` and `getSavePath()` are desktop-only (`Linux`, `macOS`, `Windows`) because Android SAF, iOS document export, and web browser sandboxes do not expose raw writable filesystem paths prior to writing content.
- **`clearTemporaryFiles()`**: Removes cached picker staging files created by `file_drop` on **Android** and **iOS** (returning `true`), and safely acts as a no-op returning `false` on Desktop and Web (while revoking tracked `blob:` object URLs on Web).
- **Reading `XFile` on Web**: On Web, `XFile.localPath` is `null` because browsers encapsulate selected/dropped files as `Blob` handles (`XFile.path` holds a `blob:` URL). Always read file contents via `await file.readAsBytes()`, `await file.readAsString()`, or `file.openRead()`.

## Installation

```yaml
dependencies:
  file_drop: ^1.0.0
```

## 1-Line Drop-in Migration

| Existing Package | Replace Import With |
| :--- | :--- |
| **Unified API (Recommended)** | `import 'package:file_drop/file_drop.dart';` |
| **`package:file_selector/file_selector.dart`** | `import 'package:file_drop/file_selector.dart';` |
| **`package:desktop_drop/desktop_drop.dart` (`0.8.x` & `0.9.2`)** | `import 'package:file_drop/desktop_drop.dart';` |

## Usage Examples

### 1. Cross-Platform File & Directory Dialogs

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_drop/file_drop.dart';
import 'package:flutter/foundation.dart';

Future<void> runFileDialogs() async {
  const imagesGroup = XTypeGroup(
    label: 'Images',
    extensions: <String>['png', 'jpg', 'webp'],
    mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
    uniformTypeIdentifiers: <String>['public.image'],
  );

  // 1. Open a single file (all 6 platforms)
  final XFile? single = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[imagesGroup],
  );
  if (single != null) {
    final Uint8List bytes = await single.readAsBytes();
    debugPrint('Opened ${single.name} (${bytes.length} bytes)');
  }

  // 2. Open multiple files (all 6 platforms)
  final List<XFile> multiple = await openFiles(
    acceptedTypeGroups: const <XTypeGroup>[imagesGroup],
  );
  debugPrint('Selected ${multiple.length} file(s)');

  // 3. Save/export bytes directly (all 6 platforms: Desktop, Mobile, Web/Wasm)
  final Uint8List reportBytes = Uint8List.fromList(utf8.encode('Hello, file_drop!'));
  final String? savedLocationOrName = await saveFile(
    bytes: reportBytes,
    suggestedName: 'report.txt',
    mimeType: 'text/plain',
  );
  if (savedLocationOrName != null) {
    debugPrint('Saved to: $savedLocationOrName');
  }

  // 4. Open and list a directory (Android, iOS, Linux, macOS, Windows)
  if (!kIsWeb) {
    final XDirectory? directory = await openDirectory(
      confirmButtonText: 'Select Folder',
    );
    if (directory != null) {
      await for (final XEntity entity in directory.list()) {
        debugPrint('Entry: ${entity.name} (${entity.path})');
      }
    }
  }

  // 5. Clean up temporary mobile picker staging files when finished
  await clearTemporaryFiles();
}
```

### 2. Cross-Platform Drag-and-Drop (`DropTarget`)

Multiple sibling, overlapping, or nested `DropTarget` widgets can coexist in the same view hierarchy across Desktop, iOS/iPadOS, Android split-screen/freeform windows, and Web/Wasm. Both `desktop_drop 0.8.x` callbacks (`onDragEntered`, `onDragUpdated`, `onDragExited`, `onDragDone`) and `desktop_drop 0.9.2` callbacks (`onEnter`, `onMove`, `onLeave`, `onDrop`, `acceptedKinds`, `onWillAccept`) are supported on the same widget:

```dart
import 'package:file_drop/file_drop.dart';
import 'package:flutter/widgets.dart';

class FileDropZone extends StatefulWidget {
  const FileDropZone({super.key});

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      acceptedKinds: const <DropItemKind>{
        DropItemKind.file,
        DropItemKind.directory,
        DropItemKind.string,
      },
      onDragEntered: (DropEventDetails details) {
        setState(() => _hovering = true);
      },
      onDragExited: (DropEventDetails details) {
        setState(() => _hovering = false);
      },
      onDragDone: (DropDoneDetails details) async {
        for (final DropItem item in details.files) {
          if (item is DropStringItem) {
            debugPrint('Dropped string (${item.mimeType}): ${item.value}');
          } else if (item.isDirectory) {
            debugPrint('Dropped directory: ${item.name} (${item.path})');
          } else {
            final bytes = await item.readAsBytes();
            debugPrint('Dropped file: ${item.name} (${bytes.length} bytes)');
          }
        }
      },
      child: Container(
        height: 180,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: _hovering
                ? const Color(0xFF2563EB)
                : const Color(0xFF94A3B8),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('Drop files, folders, or text here'),
      ),
    );
  }
}
```

## Platform Configuration Notes

### macOS App Sandbox Entitlements

If App Sandbox (`com.apple.security.app-sandbox`) is enabled in `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`, add user-selected read/write file access so macOS permits `NSOpenPanel` and `NSSavePanel`:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

If your sandboxed app persists or activates security-scoped bookmarks (`appleBookmark` / `extraAppleBookmark`) via `DesktopDrop.instance.startAccessingSecurityScopedResource`, also add:

```xml
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

### iOS (14.0+) & Android (minSdk 24)

No extra `Info.plist` usage description keys or `AndroidManifest.xml` storage permissions (`READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE`) are required. On iOS, `UIDocumentPickerViewController` and `UIDropInteraction` grant scoped access solely to user-selected items, and on Android, the Storage Access Framework (`ACTION_OPEN_DOCUMENT`, `ACTION_CREATE_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`) and `Activity.requestDragAndDropPermissions` grant temporary or persisted `content://` URI permissions directly through the system UI.

## Acknowledgements & Attribution

`file_drop` is an independent, zero-dependency implementation engineered by Infradise Inc. Its drop-in compatibility APIs are designed for seamless interoperability with:

- [`file_selector`](https://pub.dev/packages/file_selector) & [`cross_file`](https://pub.dev/packages/cross_file) by the Flutter Authors (BSD-3-Clause).
- [`desktop_drop`](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop) by MixinNetwork.

## License

Apache License 2.0 — Copyright 2026 Infradise Inc. See [LICENSE](LICENSE).
