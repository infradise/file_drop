/// Drop-in compatibility barrel for `package:file_selector/file_selector.dart`.
///
/// Migrate existing callers by changing only the package name in imports:
///
/// ```dart
/// import 'package:file_drop/file_selector.dart';
/// ```
library;

export 'src/file_item.dart'
    show
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
