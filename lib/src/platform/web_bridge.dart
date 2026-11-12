import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../mime_types.dart';
import '../selector_types.dart';
import 'platform_types.dart';

/// Whether the current runtime is executing on Web / WebAssembly.
const bool isWebRuntime = true;

/// Returns [defaultTargetPlatform] on Web runtimes.
TargetPlatform get effectiveNativePlatform => defaultTargetPlatform;

const int _webStreamChunkBytes = 256 * 1024;

final Set<String> _trackedObjectUrls = <String>{};
bool _webDropListenersAttached = false;
int _dragDepth = 0;

@JS('window')
external _JSWindow get _window;

@JS('document')
external _JSDocument get _document;

extension type _JSWindow._(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
  external int setTimeout(JSFunction handler, int timeout);
}

extension type _JSDocument._(JSObject _) implements JSObject {
  external _JSHTMLElement? get body;
  external JSObject createElement(String tagName);
}

extension type _JSCSSStyleDeclaration._(JSObject _) implements JSObject {
  external set display(String value);
}

extension type _JSHTMLElement._(JSObject _) implements JSObject {
  external _JSCSSStyleDeclaration get style;
  external JSObject appendChild(JSObject child);
  external void click();
  external void remove();
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _JSHTMLInputElement._(JSObject _) implements _JSHTMLElement {
  external set type(String value);
  external set multiple(bool value);
  external set accept(String value);
  external _JSFileList? get files;
}

extension type _JSHTMLAnchorElement._(JSObject _) implements _JSHTMLElement {
  external set href(String value);
  external set download(String value);
  external set rel(String value);
}

@JS()
@anonymous
extension type _JSBlobPropertyBag._(JSObject _) implements JSObject {
  external factory _JSBlobPropertyBag({String type});
}

@JS('Blob')
extension type _JSBlob._(JSObject _) implements JSObject {
  external factory _JSBlob(
    JSArray<JSAny?> blobParts, [
    _JSBlobPropertyBag options,
  ]);
  external double get size;
  external String get type;
  external _JSBlob slice([int start, int end, String contentType]);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _JSFile._(JSObject _) implements _JSBlob {
  external String get name;
  external double get lastModified;
}

extension type _JSFileList._(JSObject _) implements JSObject {
  external int get length;
  external _JSFile? item(int index);
}

@JS('URL')
extension type _JSURL._(JSObject _) implements JSObject {
  external static String createObjectURL(JSObject obj);
  external static void revokeObjectURL(String url);
}

extension type _JSDragEvent._(JSObject _) implements JSObject {
  external double get clientX;
  external double get clientY;
  external JSObject? get relatedTarget;
  external _JSDataTransfer? get dataTransfer;
  external void preventDefault();
  external void stopPropagation();
}

extension type _JSDataTransfer._(JSObject _) implements JSObject {
  external set dropEffect(String value);
  external _JSDataTransferItemList? get items;
  external _JSFileList? get files;
  external JSArray<JSString>? get types;
}

extension type _JSDataTransferItemList._(JSObject _) implements JSObject {
  external int get length;
}

extension type _JSDataTransferItem._(JSObject _) implements JSObject {
  external String get kind;
  external String get type;
  external _JSFile? getAsFile();
  external void getAsString(JSFunction callback);
}

extension type _JSFileSystemEntry._(JSObject _) implements JSObject {
  external bool get isFile;
  external bool get isDirectory;
  external String get name;
  external String get fullPath;
}

extension type _JSFileSystemFileEntry._(JSObject _)
    implements _JSFileSystemEntry {
  external void file(JSFunction successCallback, [JSFunction errorCallback]);
}

extension type _JSFileSystemDirectoryEntry._(JSObject _)
    implements _JSFileSystemEntry {
  external _JSFileSystemDirectoryReader createReader();
}

extension type _JSFileSystemDirectoryReader._(JSObject _) implements JSObject {
  external void readEntries(
    JSFunction successCallback, [
    JSFunction errorCallback,
  ]);
}

extension type _JSFileSystemFileHandle._(JSObject _) implements JSObject {
  external String get name;
  external JSPromise<_JSFileSystemWritableFileStream> createWritable();
}

extension type _JSFileSystemWritableFileStream._(JSObject _)
    implements JSObject {
  external JSPromise<JSAny?> write(JSAny? data);
  external JSPromise<JSAny?> close();
}

String _createTrackedObjectUrl(_JSBlob blob) {
  final url = _JSURL.createObjectURL(blob);
  _trackedObjectUrls.add(url);
  return url;
}

void _triggerAnchorDownload(_JSBlob blob, String filename) {
  final tempUrl = _JSURL.createObjectURL(blob);
  final anchor = _document.createElement('a') as _JSHTMLAnchorElement;
  anchor.style.display = 'none';
  anchor.href = tempUrl;
  anchor.download = filename.isEmpty ? 'download' : filename;
  anchor.rel = 'noopener';
  _document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  _window.setTimeout(
    (() {
      _JSURL.revokeObjectURL(tempUrl);
    }).toJS,
    1000,
  );
}

PlatformPickedFileData _wrapJSFile(_JSFile jsFile) {
  final objectUrl = _createTrackedObjectUrl(jsFile);
  final rawMime = jsFile.type;
  final mime = rawMime.isEmpty ? null : rawMime;
  final modifiedMs = jsFile.lastModified.round();
  final modified = modifiedMs > 0
      ? DateTime.fromMillisecondsSinceEpoch(modifiedMs)
      : DateTime.now();
  final size = jsFile.size.toInt();
  final backing = _WebBlobFileBacking(
    blob: jsFile,
    objectUrl: objectUrl,
    fallbackName: jsFile.name,
    lastModifiedTime: modified,
  );
  return PlatformPickedFileData(
    path: objectUrl,
    name: jsFile.name,
    mimeType: inferMimeTypeFromPath(mime, jsFile.name),
    length: size,
    lastModified: modified,
    localPath: null,
    backing: backing,
  );
}

/// Returns `false` on Web because browsers do not expose synchronous local
/// filesystem directory probes.
bool platformIsDirectorySync(String path) => false;

/// Returns `true` on Web when [path] is non-empty (such as a `blob:` URL).
Future<bool> platformPathExists(String path, {bool? isDirectoryHint}) =>
    Future<bool>.value(path.isNotEmpty);

/// Throws [UnsupportedError] when attempting raw path reads on Web without a
/// `Blob` or in-memory byte buffer.
Future<int> platformReadLength(String path) => Future<int>.error(
      UnsupportedError(
        'Cannot read file length from raw path "$path" on Web without a Blob handle.',
      ),
    );

/// Throws [UnsupportedError] when attempting raw path reads on Web without a
/// `Blob` or in-memory byte buffer.
Future<Uint8List> platformReadBytes(String path) => Future<Uint8List>.error(
      UnsupportedError(
        'Cannot read file bytes from raw path "$path" on Web without a Blob handle.',
      ),
    );

/// Throws [UnsupportedError] when attempting raw path reads on Web without a
/// `Blob` or in-memory byte buffer.
Future<String> platformReadString(
  String path, {
  Encoding encoding = utf8,
}) =>
    Future<String>.error(
      UnsupportedError(
        'Cannot read file string from raw path "$path" on Web without a Blob handle.',
      ),
    );

/// Emits an [UnsupportedError] stream when attempting raw path reads on Web
/// without a `Blob` or in-memory byte buffer.
Stream<Uint8List> platformOpenRead(String path, [int? start, int? end]) =>
    Stream<Uint8List>.error(
      UnsupportedError(
        'Cannot stream file from raw path "$path" on Web without a Blob handle.',
      ),
    );

/// Returns the epoch timestamp fallback when no `File` metadata is attached.
Future<DateTime> platformLastModified(String path) =>
    Future<DateTime>.value(DateTime.fromMillisecondsSinceEpoch(0));

/// Throws [UnsupportedError] when attempting to copy a raw filesystem path on
/// Web without a `Blob` handle.
Future<void> platformCopyPathTo(String sourcePath, String targetPath) =>
    Future<void>.error(
      UnsupportedError(
        'Cannot copy raw filesystem paths on Web without a Blob handle.',
      ),
    );

/// Triggers a browser download of [bytes] named from [targetPath] or
/// [fallbackName].
Future<void> platformSaveBytesTo(
  String targetPath,
  Uint8List bytes, {
  String? fallbackName,
  String? mimeType,
}) async {
  final extracted = extractPathBasename(targetPath);
  final downloadName = extracted.isNotEmpty
      ? extracted
      : ((fallbackName != null && fallbackName.isNotEmpty)
          ? fallbackName
          : 'download');
  final resolvedMime = inferMimeTypeFromPath(mimeType, downloadName) ??
      'application/octet-stream';
  final blob = _JSBlob(
    <JSAny?>[bytes.toJS].toJS,
    _JSBlobPropertyBag(type: resolvedMime),
  );
  _triggerAnchorDownload(blob, downloadName);
}

/// Triggers a browser download of [bytes] and returns a fresh `Blob`-backed
/// [PlatformFileBacking].
Future<PlatformFileBacking?> platformWriteBytesToPath(
  String path,
  Uint8List bytes, {
  String? suggestedName,
  String? mimeType,
}) async {
  final extracted = extractPathBasename(path);
  final downloadName = extracted.isNotEmpty
      ? extracted
      : ((suggestedName != null && suggestedName.isNotEmpty)
          ? suggestedName
          : 'download');
  final resolvedMime = inferMimeTypeFromPath(mimeType, downloadName) ??
      'application/octet-stream';
  final blob = _JSBlob(
    <JSAny?>[bytes.toJS].toJS,
    _JSBlobPropertyBag(type: resolvedMime),
  );
  _triggerAnchorDownload(blob, downloadName);
  final objectUrl = _createTrackedObjectUrl(blob);
  return _WebBlobFileBacking(
    blob: blob,
    objectUrl: objectUrl,
    fallbackName: downloadName,
    lastModifiedTime: DateTime.now(),
  );
}

/// Returns an empty stream on Web when no `FileSystemDirectoryEntry` backing is
/// present.
Stream<PlatformDirectoryEntry> platformListDirectoryPath(String path) =>
    const Stream<PlatformDirectoryEntry>.empty();

/// Unsupported on Web where files use browser `Blob` handles rather than
/// `MethodChannel` `content://` URIs.
PlatformFileBacking createChannelFileBacking(String uri) {
  throw UnsupportedError('content:// channel backings are not used on Web.');
}

/// Unsupported on Web where directories use `FileSystemDirectoryEntry` handles.
PlatformDirectoryBacking createChannelDirectoryBacking(
  String uri, {
  String? name,
}) {
  throw UnsupportedError('content:// directory backings are not used on Web.');
}

/// Opens an off-screen `<input type="file">` picker and resolves selected
/// browser `File` handles without eagerly reading file contents into RAM.
Future<List<PlatformPickedFileData>> platformOpenFiles({
  required List<XTypeGroup> acceptedTypeGroups,
  required bool allowMultiple,
}) {
  final completer = Completer<List<PlatformPickedFileData>>();
  final input = _document.createElement('input') as _JSHTMLInputElement;
  input.type = 'file';
  input.multiple = allowMultiple;
  final accept = buildWebAcceptAttribute(acceptedTypeGroups);
  if (accept.isNotEmpty) {
    input.accept = accept;
  }
  input.style.display = 'none';
  _document.body?.appendChild(input);

  Timer? focusFallbackTimer;
  late final JSFunction onChangeJs;
  late final JSFunction onCancelJs;
  late final JSFunction onWindowFocusJs;

  List<PlatformPickedFileData> readCurrentFiles() {
    final files = input.files;
    if (files == null || files.length == 0) {
      return const <PlatformPickedFileData>[];
    }
    final picked = <PlatformPickedFileData>[];
    final count = files.length;
    for (var i = 0; i < count; i++) {
      final jsFile = files.item(i);
      if (jsFile != null) {
        picked.add(_wrapJSFile(jsFile));
      }
    }
    return picked;
  }

  void finish(List<PlatformPickedFileData> result) {
    if (completer.isCompleted) {
      return;
    }
    focusFallbackTimer?.cancel();
    input.removeEventListener('change', onChangeJs);
    input.removeEventListener('cancel', onCancelJs);
    _window.removeEventListener('focus', onWindowFocusJs);
    input.remove();
    completer.complete(result);
  }

  onChangeJs = ((JSObject _) {
    finish(readCurrentFiles());
  }).toJS;

  onCancelJs = ((JSObject _) {
    finish(const <PlatformPickedFileData>[]);
  }).toJS;

  onWindowFocusJs = ((JSObject _) {
    focusFallbackTimer?.cancel();
    focusFallbackTimer = Timer(const Duration(milliseconds: 500), () {
      finish(readCurrentFiles());
    });
  }).toJS;

  input.addEventListener('change', onChangeJs);
  input.addEventListener('cancel', onCancelJs);
  _window.addEventListener('focus', onWindowFocusJs);
  input.click();
  return completer.future;
}

/// Saves [bytes] on Web using the File System Access API (`showSaveFilePicker`)
/// when available, returning `null` if the user cancels (`AbortError`), and
/// falling back to `<a download="...">` `Blob` download on Safari and Firefox.
Future<String?> platformSaveFileOnWeb({
  required Uint8List bytes,
  String? suggestedName,
  String? mimeType,
  List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
}) async {
  final fallbackName = (suggestedName != null && suggestedName.isNotEmpty)
      ? suggestedName
      : 'download';

  if ((_window as JSObject).has('showSaveFilePicker')) {
    final options = _buildSavePickerOptions(
      suggestedName: suggestedName,
      acceptedTypeGroups: acceptedTypeGroups,
    );
    try {
      final (handle, wasAborted) = await _invokeSavePickerSafe(options);
      if (wasAborted) {
        return null;
      }
      if (handle != null) {
        final writable = await handle.createWritable().toDart;
        await writable.write(bytes.toJS).toDart;
        await writable.close().toDart;
        return handle.name;
      }
    } catch (_) {
      // Fall through to anchor download if write stream or iframe security
      // blocks File System Access API.
    }
  }

  final resolvedMimeType = inferMimeTypeFromPath(mimeType, fallbackName) ??
      'application/octet-stream';
  final blob = _JSBlob(
    <JSAny?>[bytes.toJS].toJS,
    _JSBlobPropertyBag(type: resolvedMimeType),
  );
  _triggerAnchorDownload(blob, fallbackName);
  return fallbackName;
}

JSObject _buildSavePickerOptions({
  required String? suggestedName,
  required List<XTypeGroup> acceptedTypeGroups,
}) {
  final options = JSObject();
  if (suggestedName != null && suggestedName.isNotEmpty) {
    options.setProperty('suggestedName'.toJS, suggestedName.toJS);
  }
  if (acceptedTypeGroups.isNotEmpty &&
      !acceptedTypeGroups.any((XTypeGroup g) => g.allowsAll)) {
    final jsTypes = <JSObject>[];
    for (final group in acceptedTypeGroups) {
      final rawExts = group.extensions;
      if (rawExts == null || rawExts.isEmpty) {
        continue;
      }
      final validExts = rawExts
          .map((String e) => e.trim().toLowerCase())
          .where((String e) =>
              e.isNotEmpty && !e.contains('/') && !e.contains(' '))
          .map((String e) => '.$e'.toJS)
          .toList(growable: false);
      if (validExts.isEmpty) {
        continue;
      }
      final acceptObj = JSObject();
      final mimes = group.mimeTypes
          ?.map((String m) => m.trim())
          .where((String m) => m.contains('/') && !m.contains('*'))
          .toList(growable: false);
      if (mimes != null && mimes.isNotEmpty) {
        for (final mime in mimes) {
          acceptObj.setProperty(mime.toJS, validExts.toJS);
        }
      } else {
        final inferred = inferMimeTypeFromPath(null, 'file.${rawExts.first}') ??
            'application/octet-stream';
        acceptObj.setProperty(inferred.toJS, validExts.toJS);
      }
      final typeEntry = JSObject();
      if (group.label != null && group.label!.isNotEmpty) {
        typeEntry.setProperty('description'.toJS, group.label!.toJS);
      }
      typeEntry.setProperty('accept'.toJS, acceptObj);
      jsTypes.add(typeEntry);
    }
    if (jsTypes.isNotEmpty) {
      options.setProperty('types'.toJS, jsTypes.toJS);
    }
  }
  return options;
}

Future<(_JSFileSystemFileHandle?, bool)> _invokeSavePickerSafe(
  JSObject options,
) {
  final completer = Completer<(_JSFileSystemFileHandle?, bool)>();
  final JSObject promise;
  try {
    promise = (_window as JSObject).callMethod<JSObject>(
      'showSaveFilePicker'.toJS,
      options,
    );
  } catch (error) {
    return Future<(_JSFileSystemFileHandle?, bool)>.value((null, false));
  }

  final onFulfilled = ((JSAny? value) {
    if (!completer.isCompleted && value != null) {
      completer.complete(
        (_JSFileSystemFileHandle._(value as JSObject), false),
      );
    }
  }).toJS;

  final onRejected = ((JSAny? reason) {
    if (completer.isCompleted) {
      return;
    }
    var isAbort = false;
    if (reason != null && reason.typeofEquals('object')) {
      final errObj = reason as JSObject;
      final nameVal = errObj.getProperty<JSAny?>('name'.toJS);
      if (nameVal != null && nameVal.typeofEquals('string')) {
        isAbort = (nameVal as JSString).toDart == 'AbortError';
      }
    }
    completer.complete((null, isAbort));
  }).toJS;

  promise.callMethod<JSAny?>('then'.toJS, onFulfilled, onRejected);
  return completer.future;
}

/// Revokes all tracked browser `Blob` object URLs and returns `false`.
Future<bool> platformClearTemporaryFiles() {
  for (final url in _trackedObjectUrls) {
    _JSURL.revokeObjectURL(url);
  }
  _trackedObjectUrls.clear();
  return Future<bool>.value(false);
}

/// Attaches browser window `dragenter`, `dragover`, `dragleave`, and `drop`
/// listeners idempotently.
void ensureWebDropInitialized(WebDropCallbacks callbacks) {
  if (_webDropListenersAttached) {
    return;
  }
  _webDropListenersAttached = true;

  _window.addEventListener(
    'dragenter',
    ((JSObject rawEvent) {
      final event = _JSDragEvent._(rawEvent);
      _dragDepth++;
      final dt = event.dataTransfer;
      final hoverItems = _extractHoverItems(dt);
      final effect = callbacks.onHover(
        event.clientX,
        event.clientY,
        hoverItems,
        isEnter: _dragDepth == 1,
      );
      if (effect != null) {
        event.preventDefault();
        if (dt != null) {
          dt.dropEffect = effect;
        }
      } else if (dt != null) {
        dt.dropEffect = 'none';
      }
    }).toJS,
  );

  _window.addEventListener(
    'dragover',
    ((JSObject rawEvent) {
      final event = _JSDragEvent._(rawEvent);
      final dt = event.dataTransfer;
      final hoverItems = _extractHoverItems(dt);
      final effect = callbacks.onHover(
        event.clientX,
        event.clientY,
        hoverItems,
        isEnter: false,
      );
      if (effect != null) {
        event.preventDefault();
        if (dt != null) {
          dt.dropEffect = effect;
        }
      } else if (dt != null) {
        dt.dropEffect = 'none';
      }
    }).toJS,
  );

  _window.addEventListener(
    'dragleave',
    ((JSObject rawEvent) {
      final event = _JSDragEvent._(rawEvent);
      if (_dragDepth > 0) {
        _dragDepth--;
      }
      if (_dragDepth <= 0 || event.relatedTarget == null) {
        _dragDepth = 0;
        callbacks.onLeave(event.clientX, event.clientY);
      }
    }).toJS,
  );

  _window.addEventListener(
    'drop',
    ((JSObject rawEvent) {
      final event = _JSDragEvent._(rawEvent);
      _dragDepth = 0;
      final dt = event.dataTransfer;
      final x = event.clientX;
      final y = event.clientY;
      final hoverItems = _extractHoverItems(dt);
      final accepted = callbacks.canAcceptDrop(x, y, hoverItems);
      if (accepted) {
        event.preventDefault();
        event.stopPropagation();
      } else if (!callbacks.hasRawListeners()) {
        callbacks.onLeave(x, y);
        return;
      }

      // Extract all DataTransferItem handles synchronously before the browser
      // invalidates the DataTransfer object after this event tick.
      final pending = _collectDroppedItemsSync(dt);
      unawaited(
        Future.wait(pending).then((List<WebDroppedItemData?> resolved) async {
          final nonNull =
              resolved.whereType<WebDroppedItemData>().toList(growable: false);
          await callbacks.onDrop(x, y, nonNull);
        }),
      );
    }).toJS,
  );
}

List<WebHoverItemData> _extractHoverItems(_JSDataTransfer? dt) {
  if (dt == null) {
    return const <WebHoverItemData>[];
  }
  final items = dt.items;
  if (items != null && items.length > 0) {
    final result = <WebHoverItemData>[];
    final count = items.length;
    for (var i = 0; i < count; i++) {
      final rawObj = (items as JSObject).getProperty<JSObject?>(i.toJS);
      if (rawObj == null) {
        continue;
      }
      final item = _JSDataTransferItem._(rawObj);
      final kind = item.kind;
      final rawType = item.type;
      if (kind == 'file') {
        result.add(
          WebHoverItemData(
            isString: false,
            mimeType: rawType.isEmpty ? null : rawType,
          ),
        );
      } else if (kind == 'string') {
        result.add(
          WebHoverItemData(
            isString: true,
            mimeType: rawType.isEmpty ? 'text/plain' : rawType,
          ),
        );
      }
    }
    if (result.isNotEmpty) {
      return result;
    }
  }

  final jsTypes = dt.types;
  if (jsTypes != null) {
    final dartTypes = jsTypes.toDart.map((JSString s) => s.toDart).toSet();
    if (dartTypes.contains('Files')) {
      return const <WebHoverItemData>[WebHoverItemData(isString: false)];
    }
    if (dartTypes.contains('text/uri-list')) {
      return const <WebHoverItemData>[
        WebHoverItemData(isString: true, mimeType: 'text/uri-list'),
      ];
    }
    if (dartTypes.contains('text/plain')) {
      return const <WebHoverItemData>[
        WebHoverItemData(isString: true, mimeType: 'text/plain'),
      ];
    }
  }
  return const <WebHoverItemData>[];
}

List<Future<WebDroppedItemData?>> _collectDroppedItemsSync(
  _JSDataTransfer? dt,
) {
  if (dt == null) {
    return const <Future<WebDroppedItemData?>>[];
  }
  final pending = <Future<WebDroppedItemData?>>[];
  var sawFileOrDirFromItems = false;

  final items = dt.items;
  if (items != null && items.length > 0) {
    final count = items.length;
    for (var i = 0; i < count; i++) {
      final rawObj = (items as JSObject).getProperty<JSObject?>(i.toJS);
      if (rawObj == null) {
        continue;
      }
      final item = _JSDataTransferItem._(rawObj);
      final kind = item.kind;
      if (kind == 'file') {
        sawFileOrDirFromItems = true;
        if (rawObj.has('webkitGetAsEntry')) {
          final rawEntry = rawObj.callMethod<JSObject?>(
            'webkitGetAsEntry'.toJS,
          );
          if (rawEntry != null) {
            final entry = _JSFileSystemEntry._(rawEntry);
            if (entry.isDirectory) {
              final virtualPath =
                  entry.fullPath.isNotEmpty ? entry.fullPath : entry.name;
              final dirEntry = _JSFileSystemDirectoryEntry._(rawEntry);
              pending.add(
                Future<WebDroppedItemData?>.value(
                  WebDroppedDirectory(
                    name: entry.name,
                    path: virtualPath,
                    backing: _WebDirectoryEntryBacking(
                      dirEntry,
                      virtualPath: virtualPath,
                    ),
                  ),
                ),
              );
              continue;
            }
            if (entry.isFile) {
              final directFile = item.getAsFile();
              if (directFile != null) {
                pending.add(
                  Future<WebDroppedItemData?>.value(
                    WebDroppedFile(_wrapJSFile(directFile)),
                  ),
                );
              } else {
                final fileEntry = _JSFileSystemFileEntry._(rawEntry);
                pending.add(
                  _resolveFileEntry(fileEntry).then(
                    (_JSFile? f) =>
                        f == null ? null : WebDroppedFile(_wrapJSFile(f)),
                  ),
                );
              }
              continue;
            }
          }
        }
        final jsFile = item.getAsFile();
        if (jsFile != null) {
          pending.add(
            Future<WebDroppedItemData?>.value(
              WebDroppedFile(_wrapJSFile(jsFile)),
            ),
          );
        }
      } else if (kind == 'string') {
        final mime = item.type.isEmpty ? 'text/plain' : item.type;
        pending.add(_readDataTransferString(item, mime));
      }
    }
  }

  if (!sawFileOrDirFromItems) {
    final files = dt.files;
    if (files != null && files.length > 0) {
      final count = files.length;
      for (var i = 0; i < count; i++) {
        final jsFile = files.item(i);
        if (jsFile != null) {
          pending.add(
            Future<WebDroppedItemData?>.value(
              WebDroppedFile(_wrapJSFile(jsFile)),
            ),
          );
        }
      }
    }
  }

  return pending;
}

Future<WebDroppedItemData?> _readDataTransferString(
  _JSDataTransferItem item,
  String mimeType,
) {
  final completer = Completer<WebDroppedItemData?>();
  item.getAsString(
    ((JSString value) {
      if (!completer.isCompleted) {
        completer.complete(
          WebDroppedString(mimeType: mimeType, value: value.toDart),
        );
      }
    }).toJS,
  );
  return completer.future;
}

Future<_JSFile?> _resolveFileEntry(_JSFileSystemFileEntry fileEntry) {
  final completer = Completer<_JSFile?>();
  final onSuccess = ((JSObject fileObj) {
    if (!completer.isCompleted) {
      completer.complete(_JSFile._(fileObj));
    }
  }).toJS;
  final onError = ((JSAny? _) {
    if (!completer.isCompleted) {
      completer.complete(null);
    }
  }).toJS;
  fileEntry.file(onSuccess, onError);
  return completer.future;
}

final class _WebBlobFileBacking implements PlatformFileBacking {
  _WebBlobFileBacking({
    required _JSBlob blob,
    required String objectUrl,
    required String fallbackName,
    required DateTime lastModifiedTime,
  })  : _blob = blob,
        _objectUrl = objectUrl,
        _fallbackName = fallbackName,
        _lastModifiedTime = lastModifiedTime;

  final _JSBlob _blob;
  final String _objectUrl;
  final String _fallbackName;
  final DateTime _lastModifiedTime;

  @override
  String? get localPath => null;

  @override
  String get uri => _objectUrl;

  @override
  Future<bool> exists() => Future<bool>.value(true);

  @override
  Future<int> length() => Future<int>.value(_blob.size.toInt());

  @override
  Future<DateTime> lastModified() => Future<DateTime>.value(_lastModifiedTime);

  @override
  Future<Uint8List> readAsBytes() async {
    final arrayBuffer = await _blob.arrayBuffer().toDart;
    return arrayBuffer.toDart.asUint8List();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final bytes = await readAsBytes();
    return encoding.decode(bytes);
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final totalLength = _blob.size.toInt();
    final effectiveStart = (start ?? 0).clamp(0, totalLength);
    final effectiveEnd =
        (end ?? totalLength).clamp(effectiveStart, totalLength);
    if (effectiveStart >= effectiveEnd) {
      return;
    }
    var offset = effectiveStart;
    while (offset < effectiveEnd) {
      final nextEnd = (offset + _webStreamChunkBytes < effectiveEnd)
          ? offset + _webStreamChunkBytes
          : effectiveEnd;
      final chunkBlob = _blob.slice(offset, nextEnd);
      final chunkBuffer = await chunkBlob.arrayBuffer().toDart;
      yield chunkBuffer.toDart.asUint8List();
      offset = nextEnd;
    }
  }

  @override
  Future<void> saveTo(String targetPath) async {
    final extracted = extractPathBasename(targetPath);
    final downloadName = extracted.isNotEmpty
        ? extracted
        : (_fallbackName.isNotEmpty ? _fallbackName : 'download');
    _triggerAnchorDownload(_blob, downloadName);
  }

  @override
  Future<PlatformFileBacking?> writeAsBytes(
    Uint8List bytes, {
    required String suggestedName,
    String? mimeType,
  }) {
    final name = suggestedName.isNotEmpty ? suggestedName : _fallbackName;
    return platformWriteBytesToPath(
      name,
      bytes,
      suggestedName: name,
      mimeType: mimeType,
    );
  }
}

final class _WebDirectoryEntryBacking implements PlatformDirectoryBacking {
  _WebDirectoryEntryBacking(
    this._dirEntry, {
    required String virtualPath,
  }) : _virtualPath = virtualPath;

  final _JSFileSystemDirectoryEntry _dirEntry;
  final String _virtualPath;

  @override
  String? get localPath => null;

  @override
  String get uri => _virtualPath;

  @override
  String? get resolvedName => _dirEntry.name;

  @override
  void updateGrantedAccess({required String uri, String? name}) {}

  @override
  Future<bool> exists() => Future<bool>.value(true);

  @override
  Stream<PlatformDirectoryEntry> list() async* {
    final reader = _dirEntry.createReader();
    while (true) {
      final batch = await _readBatch(reader);
      if (batch.isEmpty) {
        break;
      }
      for (final entry in batch) {
        if (entry.isDirectory) {
          final childPath =
              entry.fullPath.isNotEmpty ? entry.fullPath : entry.name;
          final childDir = _JSFileSystemDirectoryEntry._(entry as JSObject);
          yield PlatformChildDirectory(
            name: entry.name,
            path: childPath,
            localPath: null,
            backing: _WebDirectoryEntryBacking(
              childDir,
              virtualPath: childPath,
            ),
          );
        } else if (entry.isFile) {
          final childFileEntry = _JSFileSystemFileEntry._(entry as JSObject);
          final jsFile = await _resolveFileEntry(childFileEntry);
          if (jsFile != null) {
            final picked = _wrapJSFile(jsFile);
            yield PlatformChildFile(
              name: picked.name,
              path: picked.path,
              localPath: null,
              mimeType: picked.mimeType,
              backing: picked.backing,
            );
          }
        }
      }
    }
  }

  Future<List<_JSFileSystemEntry>> _readBatch(
    _JSFileSystemDirectoryReader reader,
  ) {
    final completer = Completer<List<_JSFileSystemEntry>>();
    final onSuccess = ((JSArray<JSObject> entries) {
      if (!completer.isCompleted) {
        final dartEntries =
            entries.toDart.map(_JSFileSystemEntry._).toList(growable: false);
        completer.complete(dartEntries);
      }
    }).toJS;
    final onError = ((JSAny? error) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Failed to read Web directory entries: $error'),
        );
      }
    }).toJS;
    reader.readEntries(onSuccess, onError);
    return completer.future;
  }
}
