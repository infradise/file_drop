/// Web and WebAssembly (`dart2wasm`) plugin registration entrypoint for
/// `file_drop`.
library;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/channel.dart';

/// Web platform implementation of `file_drop` using pure `dart:js_interop`
/// with zero external hosted dependencies.
class FileDropWeb {
  /// Creates a [FileDropWeb] plugin instance.
  const FileDropWeb();

  /// Registers the Web drag-and-drop and file selector bindings with Flutter's
  /// Web plugin [registrar].
  static void registerWith(Registrar registrar) {
    DesktopDrop.instance.init();
  }
}
