import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_drop/desktop_drop.dart' as dd_barrel;
import 'package:file_drop/file_drop.dart';
import 'package:file_drop/file_selector.dart' as fs_barrel;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sends a simulated native->Dart [MethodCall] over `com.infradise.file_drop`.
Future<void> _sendNativeDropCall(String method, [Object? arguments]) async {
  final encoded = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    DesktopDrop.channel.name,
    encoded,
    (ByteData? _) {},
  );
}

/// Entrypoint for the `file_drop` unit and widget test suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Compatibility Barrels & Type Identity', () {
    test('XFile, DropItem, and FileDropItem resolve to identical type', () {
      expect(identical(XFile, FileDropItem), isTrue);
      expect(identical(DropItem, FileDropItem), isTrue);
      expect(identical(fs_barrel.XFile, FileDropItem), isTrue);
      expect(identical(dd_barrel.DropItem, FileDropItem), isTrue);
      expect(identical(dd_barrel.XFile, FileDropItem), isTrue);
    });

    test('file_selector and desktop_drop barrels expose expected symbols', () {
      const group = fs_barrel.XTypeGroup(
        label: 'Text',
        extensions: <String>['txt'],
      );
      const saveLoc = fs_barrel.FileSaveLocation(
        '/tmp/out.txt',
        activeFilter: group,
      );
      const dropFile = dd_barrel.DropItemFile('/tmp/a.txt');
      const dropDir = dd_barrel.DropItemDirectory('/tmp/folder');

      expect(saveLoc.path, '/tmp/out.txt');
      expect(saveLoc.activeFilter, same(group));
      expect(dropFile, isA<FileDropItem>());
      expect(dropDir, isA<FileDropItem>());
      expect(fs_barrel.openFile, same(openFile));
      expect(dd_barrel.DropTarget.new, isNotNull);
      expect(DesktopDrop.channel.name, 'com.infradise.file_drop');
    });
  });

  group('FileDropItem / XFile / DropItem I/O & Path Handling', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('file_drop_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('extracts basename across POSIX, Windows, mixed, and trailing slashes',
        () {
      expect(
        const FileDropItem('/Users/user/Documents/report.pdf').name,
        'report.pdf',
      );
      expect(
        const FileDropItem(r'C:\Users\user\Desktop\budget_2026.xlsx').name,
        'budget_2026.xlsx',
      );
      expect(
        const FileDropItem(r'D:\workspace/project\assets/logo.png').name,
        'logo.png',
      );
      expect(
        const FileDropItem('/Users/user/Downloads/archive_dir/').name,
        'archive_dir',
      );
      expect(
        const FileDropItem(r'C:\Temp\my_folder\').name,
        'my_folder',
      );
      expect(const FileDropItem('').name, '');
      expect(const FileDropItem('/').name, '');
      expect(
        const FileDropItem('/tmp/raw.bin', name: 'override_name.bin').name,
        'override_name.bin',
      );
    });

    test(
        'reads bytes, UTF-8/Latin1 strings, length, and lastModified from disk',
        () async {
      final filePath = '${tempDir.path}/한글_샘플.txt';
      const content = 'Hello file_drop! 안녕하세요 🚀\nLine 2';
      final diskFile = File(filePath);
      await diskFile.writeAsString(content, encoding: utf8);

      final item = XFile(filePath, mimeType: 'text/plain');
      expect(item.path, filePath);
      expect(item.name, '한글_샘플.txt');
      expect(item.mimeType, 'text/plain');
      expect(item.isDirectory, isFalse);

      final expectedBytes = utf8.encode(content);
      expect(await item.length(), expectedBytes.length);
      expect(await item.readAsBytes(), Uint8List.fromList(expectedBytes));
      expect(await item.readAsString(), content);

      final modTime = await item.lastModified();
      final diskModTime = await diskFile.lastModified();
      expect(modTime, diskModTime);
    });

    test('reads Latin1 encoded text accurately via encoding parameter',
        () async {
      final filePath = '${tempDir.path}/latin1.txt';
      final latinBytes = latin1.encode('Caf\u00e9 r\u00e9sum\u00e9');
      await File(filePath).writeAsBytes(latinBytes);

      final item = FileDropItem(filePath);
      expect(
        await item.readAsString(encoding: latin1),
        'Café résumé',
      );
    });

    test('openRead streams full file and exact byte ranges [start, end)',
        () async {
      final filePath = '${tempDir.path}/range.bin';
      final bytes = Uint8List.fromList(List<int>.generate(32, (int i) => i));
      await File(filePath).writeAsBytes(bytes);

      final item = XFile(filePath);

      final fullChunks = await item.openRead().toList();
      final fullMerged = fullChunks.expand((Uint8List c) => c).toList();
      expect(fullMerged, bytes);

      final sliceChunks = await item.openRead(5, 15).toList();
      final sliceMerged = sliceChunks.expand((Uint8List c) => c).toList();
      expect(sliceMerged, bytes.sublist(5, 15));
    });

    test('saveTo copies disk file to target path byte-for-byte', () async {
      final sourcePath = '${tempDir.path}/source.dat';
      final destPath = '${tempDir.path}/copied.dat';
      final payload = Uint8List.fromList(<int>[10, 20, 30, 40, 50, 255]);
      await File(sourcePath).writeAsBytes(payload);

      final item = FileDropItem(sourcePath);
      await item.saveTo(destPath);

      expect(File(destPath).existsSync(), isTrue);
      expect(await File(destPath).readAsBytes(), payload);
    });

    test('FileDropItem.fromData supports in-memory I/O, slicing, and saveTo',
        () async {
      final rawBytes = Uint8List.fromList(utf8.encode('0123456789ABCDEF'));
      final fixedTime = DateTime.utc(2026, 11, 12, 6, 0);
      final item = XFile.fromData(
        rawBytes,
        name: 'memory.txt',
        mimeType: 'text/plain',
        lastModified: fixedTime,
      );

      expect(item.path, '');
      expect(item.name, 'memory.txt');
      expect(item.mimeType, 'text/plain');
      expect(item.isDirectory, isFalse);
      expect(await item.length(), 16);
      expect(await item.lastModified(), fixedTime);
      expect(await item.readAsString(), '0123456789ABCDEF');
      expect(await item.readAsBytes(), rawBytes);

      final sliced = await item.openRead(4, 10).single;
      expect(utf8.decode(sliced), '456789');

      final savedPath = '${tempDir.path}/saved_from_memory.txt';
      await item.saveTo(savedPath);
      expect(await File(savedPath).readAsString(), '0123456789ABCDEF');
    });

    test('isDirectory detects real directories and respects subclass flags',
        () async {
      final subDir = Directory('${tempDir.path}/nested_folder');
      await subDir.create();
      final regularFile = File('${tempDir.path}/note.md');
      await regularFile.writeAsString('# Title');

      expect(FileDropItem(subDir.path).isDirectory, isTrue);
      expect(FileDropItem(regularFile.path).isDirectory, isFalse);

      const cachedDir = DropItemDirectory('/nonexistent/virtual_folder');
      const cachedFile = DropItemFile('/nonexistent/virtual_file.txt');
      expect(cachedDir.isDirectory, isTrue);
      expect(cachedFile.isDirectory, isFalse);
    });

    test('preserves extraAppleBookmark and fromPromise metadata', () {
      final bookmark = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final item = DropItemFile(
        '/Users/user/secret.pdf',
        extraAppleBookmark: bookmark,
        fromPromise: true,
      );
      expect(item.extraAppleBookmark, bookmark);
      expect(item.fromPromise, isTrue);
    });
  });

  group('XTypeGroup & FileSaveLocation Serialization', () {
    test('allowsAll is true when empty and false when any filter is set', () {
      expect(const XTypeGroup().allowsAll, isTrue);
      expect(const XTypeGroup(label: 'All Files').allowsAll, isTrue);
      expect(const XTypeGroup(label: 'All Files').allowsAny, isTrue);

      expect(
        const XTypeGroup(extensions: <String>['dart']).allowsAll,
        isFalse,
      );
      expect(
        const XTypeGroup(mimeTypes: <String>['text/plain']).allowsAll,
        isFalse,
      );
      expect(
        const XTypeGroup(macUTIs: <String>['public.data']).allowsAll,
        isFalse,
      );
      expect(
        const XTypeGroup(webWildCards: <String>['image/*']).allowsAll,
        isFalse,
      );
    });

    test('normalizes leading dots on extensions and serializes via toMap', () {
      const group = XTypeGroup(
        label: 'Images',
        extensions: <String>['.png', '*.jpg', 'webp'],
        mimeTypes: <String>['image/png', 'image/jpeg'],
        macUTIs: <String>['public.image'],
      );

      expect(group.extensions, <String>['png', 'jpg', 'webp']);
      expect(group.uniformTypeIdentifiers, <String>['public.image']);

      final map = group.toMap();
      expect(map['label'], 'Images');
      expect(map['extensions'], <String>['png', 'jpg', 'webp']);
      expect(map['mimeTypes'], <String>['image/png', 'image/jpeg']);
      expect(map['macUTIs'], <String>['public.image']);
      expect(map['uniformTypeIdentifiers'], <String>['public.image']);
      expect(group.toJSON(), map);
    });
  });

  group('MethodChannel Contract Tests (Dialogs & Bookmarks)', () {
    final recordedCalls = <MethodCall>[];

    setUp(() {
      recordedCalls.clear();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel, null);
    });

    test('openFile serializes parameters and returns XFile or null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return '/Users/user/selected.txt';
      });

      const group = XTypeGroup(
        label: 'Text',
        extensions: <String>['.txt'],
        macUTIs: <String>['public.plain-text'],
      );
      final file = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[group],
        initialDirectory: '/Users/user',
        confirmButtonText: 'Choose',
      );

      expect(file, isNotNull);
      expect(file!.path, '/Users/user/selected.txt');
      expect(file.name, 'selected.txt');
      expect(recordedCalls, hasLength(1));
      expect(recordedCalls.single.method, 'openFile');

      final args = recordedCalls.single.arguments as Map<Object?, Object?>;
      expect(args['initialDirectory'], '/Users/user');
      expect(args['confirmButtonText'], 'Choose');
      final groups = args['acceptedTypeGroups'] as List<Object?>;
      expect(groups, hasLength(1));
      expect((groups.single as Map<Object?, Object?>)['extensions'], <String>[
        'txt',
      ]);

      // Verify cancellation returns null.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return null;
      });
      expect(await openFile(), isNull);
    });

    test('openFiles returns List<XFile> and empty list on cancellation',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return <String>['/tmp/a.png', '/tmp/b.jpg'];
      });

      final files = await openFiles(confirmButtonText: 'Import');
      expect(recordedCalls.single.method, 'openFiles');
      expect(files, hasLength(2));
      expect(files[0].name, 'a.png');
      expect(files[1].name, 'b.jpg');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return <String>[];
      });
      expect(await openFiles(), isEmpty);
    });

    test('getSaveLocation & getSavePath resolve path and activeFilter',
        () async {
      const csvFilter = XTypeGroup(label: 'CSV', extensions: <String>['csv']);
      const jsonFilter =
          XTypeGroup(label: 'JSON', extensions: <String>['json']);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return <String, Object?>{
          'path': '/Users/user/export.json',
          'activeFilterIndex': 1,
        };
      });

      final location = await getSaveLocation(
        acceptedTypeGroups: const <XTypeGroup>[csvFilter, jsonFilter],
        initialDirectory: '/Users/user',
        suggestedName: 'export.json',
        confirmButtonText: 'Export',
      );

      expect(recordedCalls.single.method, 'getSaveLocation');
      final args = recordedCalls.single.arguments as Map<Object?, Object?>;
      expect(args['suggestedName'], 'export.json');
      expect(args['confirmButtonText'], 'Export');

      expect(location, isNotNull);
      expect(location!.path, '/Users/user/export.json');
      expect(location.activeFilter, same(jsonFilter));

      final pathOnly = await getSavePath(suggestedName: 'export.json');
      expect(pathOnly, '/Users/user/export.json');

      // Cancellation check.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return null;
      });
      expect(await getSaveLocation(), isNull);
      expect(await getSavePath(), isNull);
    });

    test('getDirectoryPath and getDirectoryPaths handle selection and cancel',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        if (call.method == 'getDirectoryPath') {
          return '/Users/user/Projects';
        }
        if (call.method == 'getDirectoryPaths') {
          return <String>['/Users/user/Projects', '/Users/user/Downloads'];
        }
        return null;
      });

      final singleDir = await getDirectoryPath(
        initialDirectory: '/Users/user',
        confirmButtonText: 'Select Folder',
      );
      expect(singleDir, '/Users/user/Projects');
      expect(recordedCalls.first.method, 'getDirectoryPath');

      final multiDirs = await getDirectoryPaths(confirmButtonText: 'Select');
      expect(multiDirs, <String>[
        '/Users/user/Projects',
        '/Users/user/Downloads',
      ]);
      expect(recordedCalls.last.method, 'getDirectoryPaths');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return call.method == 'getDirectoryPaths' ? <String>[] : null;
      });
      expect(await getDirectoryPath(), isNull);
      expect(await getDirectoryPaths(), isEmpty);
    });

    test('DesktopDrop security-scoped bookmark methods invoke channel cleanly',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return true;
      });

      // Empty bookmarks short-circuit without invoking platform channel.
      expect(
        await DesktopDrop.instance.startAccessingSecurityScopedResource(
          bookmark: Uint8List(0),
        ),
        isFalse,
      );
      expect(
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(
          bookmark: Uint8List(0),
        ),
        isTrue,
      );
      expect(recordedCalls, isEmpty);

      final nonEmpty = Uint8List.fromList(<int>[0xAA, 0xBB]);
      expect(
        await DesktopDrop.instance.startAccessingSecurityScopedResource(
          bookmark: nonEmpty,
        ),
        isTrue,
      );
      expect(
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(
          bookmark: nonEmpty,
        ),
        isTrue,
      );
      expect(recordedCalls, hasLength(2));
      expect(
        recordedCalls[0].method,
        'startAccessingSecurityScopedResource',
      );
      expect(
        recordedCalls[1].method,
        'stopAccessingSecurityScopedResource',
      );
    });
  });

  group('DropTarget Widget & Multi-Zone Hit-Testing Tests', () {
    setUp(() {
      DesktopDrop.instance.resetForTesting();
    });

    testWidgets(
        'computes accurate localPosition and fires hover transitions in order',
        (WidgetTester tester) async {
      final events = <String>[];
      DropEventDetails? lastEntered;
      DropEventDetails? lastUpdated;
      DropEventDetails? lastExited;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 80,
                top: 60,
                width: 200,
                height: 150,
                child: DropTarget(
                  onDragEntered: (DropEventDetails details) {
                    events.add('enter');
                    lastEntered = details;
                  },
                  onDragUpdated: (DropEventDetails details) {
                    events.add('update');
                    lastUpdated = details;
                  },
                  onDragExited: (DropEventDetails details) {
                    events.add('exit');
                    lastExited = details;
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      );

      // Drag enters outside target at (20, 20) -> ignored.
      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 20, 'y': 20},
      );
      expect(events, isEmpty);

      // Drag moves inside target at (110, 100) -> local (30, 40).
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 110, 'y': 100},
      );
      expect(events, <String>['enter']);
      expect(lastEntered!.globalPosition, const Offset(110, 100));
      expect(lastEntered!.localPosition, const Offset(30, 40));

      // Drag moves within target at (180, 160) -> local (100, 100).
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 180, 'y': 160},
      );
      expect(events, <String>['enter', 'update']);
      expect(lastUpdated!.globalPosition, const Offset(180, 160));
      expect(lastUpdated!.localPosition, const Offset(100, 100));

      // Drag leaves window -> fires exit.
      await _sendNativeDropCall(
        'onDragExited',
        <String, double>{'x': 350, 'y': 300},
      );
      expect(events, <String>['enter', 'update', 'exit']);
      expect(lastExited!.globalPosition, const Offset(350, 300));
    });

    testWidgets(
        'sibling DropTargets transition cleanly across boundary and isolate drop',
        (WidgetTester tester) async {
      final log = <String>[];
      DropDoneDetails? zoneADrop;
      DropDoneDetails? zoneBDrop;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 200,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: DropTarget(
                      onDragEntered: (_) => log.add('A:enter'),
                      onDragUpdated: (_) => log.add('A:update'),
                      onDragExited: (_) => log.add('A:exit'),
                      onDragDone: (DropDoneDetails d) {
                        log.add('A:done');
                        zoneADrop = d;
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: DropTarget(
                      onDragEntered: (_) => log.add('B:enter'),
                      onDragUpdated: (_) => log.add('B:update'),
                      onDragExited: (_) => log.add('B:exit'),
                      onDragDone: (DropDoneDetails d) {
                        log.add('B:done');
                        zoneBDrop = d;
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Enter Zone A at (50, 50).
      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 50, 'y': 50},
      );
      expect(log, <String>['A:enter']);

      // Cross boundary into Zone B at (250, 80) -> local in B is (50, 80).
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 250, 'y': 80},
      );
      expect(log, <String>['A:enter', 'A:exit', 'B:enter']);

      // Drop on Zone B at (260, 90).
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 260.0,
        'y': 90.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/doc.pdf', 'isDirectory': false},
        ],
      });

      expect(log, <String>['A:enter', 'A:exit', 'B:enter', 'B:exit', 'B:done']);
      expect(zoneADrop, isNull);
      expect(zoneBDrop, isNotNull);
      expect(zoneBDrop!.localPosition, const Offset(60, 90));
      expect(zoneBDrop!.files.single.path, '/tmp/doc.pdf');
    });

    testWidgets(
        'nested DropTargets prioritize inner target and support translucent propagation',
        (WidgetTester tester) async {
      final log = <String>[];

      Widget buildTree({required HitTestBehavior innerBehavior}) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: DropTarget(
                onDragEntered: (_) => log.add('outer:enter'),
                onDragExited: (_) => log.add('outer:exit'),
                onDragDone: (_) => log.add('outer:done'),
                child: Center(
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: DropTarget(
                      behavior: innerBehavior,
                      onDragEntered: (_) => log.add('inner:enter'),
                      onDragExited: (_) => log.add('inner:exit'),
                      onDragDone: (_) => log.add('inner:done'),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      await tester
          .pumpWidget(buildTree(innerBehavior: HitTestBehavior.deferToChild));

      // Outer area (20, 20) -> outer enters.
      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 20, 'y': 20},
      );
      expect(log, <String>['outer:enter']);

      // Move into inner center (150, 150) -> outer exits, inner enters!
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 150, 'y': 150},
      );
      expect(log, <String>['outer:enter', 'outer:exit', 'inner:enter']);

      // Drop at inner center -> only inner receives onDragDone.
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 150.0,
        'y': 150.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/inner.txt', 'isDirectory': false},
        ],
      });
      expect(
        log,
        <String>[
          'outer:enter',
          'outer:exit',
          'inner:enter',
          'inner:exit',
          'inner:done',
        ],
      );

      // Now rebuild with HitTestBehavior.translucent on inner target.
      log.clear();
      await tester
          .pumpWidget(buildTree(innerBehavior: HitTestBehavior.translucent));
      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 150, 'y': 150},
      );
      expect(log, <String>['inner:enter', 'outer:enter']);
    });

    testWidgets(
        'enable: false bypasses DropTarget and exits cleanly if disabled mid-drag',
        (WidgetTester tester) async {
      var isEnabled = true;
      final events = <String>[];
      late StateSetter rebuildHost;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuildHost = setState;
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: DropTarget(
                    enable: isEnabled,
                    onDragEntered: (_) => events.add('enter'),
                    onDragUpdated: (_) => events.add('update'),
                    onDragExited: (_) => events.add('exit'),
                    onDragDone: (_) => events.add('done'),
                    child: const SizedBox.expand(),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 50, 'y': 50},
      );
      expect(events, <String>['enter']);

      // Disable while drag is hovering -> immediately fires exit!
      rebuildHost(() => isEnabled = false);
      await tester.pump();
      expect(events, <String>['enter', 'exit']);

      // Further updates and drops while disabled are completely ignored.
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 60, 'y': 60},
      );
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 60.0,
        'y': 60.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/ignored.txt', 'isDirectory': false},
        ],
      });
      expect(events, <String>['enter', 'exit']);
    });

    testWidgets(
        'dispatches DropItemFile and DropItemDirectory with bookmark & rawText',
        (WidgetTester tester) async {
      DropDoneDetails? received;
      final bookmarkBytes = Uint8List.fromList(<int>[0xDE, 0xAD, 0xBE, 0xEF]);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 200,
              child: DropTarget(
                onDragDone: (DropDoneDetails details) {
                  received = details;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 100.0,
        'y': 75.0,
        'rawText':
            'file:///Users/user/photo.png\r\nfile:///Users/user/Albums\r\n',
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'path': '/Users/user/photo.png',
            'isDirectory': false,
            'appleBookmark': bookmarkBytes,
            'fromPromise': false,
          },
          <String, Object?>{
            'path': '/Users/user/Albums',
            'isDirectory': true,
            'fromPromise': false,
          },
        ],
      });

      expect(received, isNotNull);
      expect(received!.globalPosition, const Offset(100, 75));
      expect(received!.localPosition, const Offset(100, 75));
      expect(
        received!.rawText,
        'file:///Users/user/photo.png\r\nfile:///Users/user/Albums\r\n',
      );
      expect(received!.files, hasLength(2));

      final first = received!.files[0];
      final second = received!.files[1];

      expect(first, isA<DropItemFile>());
      expect(first.isDirectory, isFalse);
      expect(first.name, 'photo.png');
      expect(first.extraAppleBookmark, bookmarkBytes);

      expect(second, isA<DropItemDirectory>());
      expect(second.isDirectory, isTrue);
      expect(second.name, 'Albums');
    });

    testWidgets('DesktopDrop raw drop event listeners receive window events',
        (WidgetTester tester) async {
      final rawEvents = <DropEvent>[];
      void listener(DropEvent event) => rawEvents.add(event);

      DesktopDrop.instance.addRawDropEventListener(listener);
      addTearDown(
          () => DesktopDrop.instance.removeRawDropEventListener(listener));

      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 12, 'y': 34},
      );
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 56, 'y': 78},
      );
      await _sendNativeDropCall(
        'onDragExited',
        <String, double>{'x': 90, 'y': 99},
      );

      expect(rawEvents, hasLength(3));
      expect(rawEvents[0], isA<DropEnterEvent>());
      expect(rawEvents[0].location, const Offset(12, 34));
      expect(rawEvents[1], isA<DropUpdateEvent>());
      expect(rawEvents[1].location, const Offset(56, 78));
      expect(rawEvents[2], isA<DropExitEvent>());
      expect(rawEvents[2].location, const Offset(90, 99));
    });

    testWidgets('Stack overlapping DropTargets select top-most painted target',
        (WidgetTester tester) async {
      final hits = <String>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: 200,
                height: 200,
                child: DropTarget(
                  onDragEntered: (_) => hits.add('bottom:enter'),
                  onDragDone: (_) => hits.add('bottom:done'),
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                left: 50,
                top: 50,
                width: 150,
                height: 150,
                child: DropTarget(
                  onDragEntered: (_) => hits.add('top:enter'),
                  onDragDone: (_) => hits.add('top:done'),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      );

      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 100, 'y': 100},
      );
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 100.0,
        'y': 100.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/top.txt', 'isDirectory': false},
        ],
      });

      expect(hits, <String>['top:enter', 'top:done']);
    });

    testWidgets(
        'supports legacy desktop_drop method and list coordinate format',
        (WidgetTester tester) async {
      DropEventDetails? entered;
      DropDoneDetails? dropped;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: DropTarget(
                onDragEntered: (DropEventDetails d) => entered = d,
                onDragDone: (DropDoneDetails d) => dropped = d,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      await _sendNativeDropCall('entered', <double>[42.0, 84.0]);
      expect(entered?.localPosition, const Offset(42, 84));

      await _sendNativeDropCall(
        'performOperation',
        <String>['/tmp/legacy_a.txt', '/tmp/legacy_b.txt'],
      );
      expect(dropped, isNotNull);
      expect(dropped!.files, hasLength(2));
      expect(dropped!.files[0].name, 'legacy_a.txt');
    });

    testWidgets('disposing a hovered DropTarget unregisters cleanly',
        (WidgetTester tester) async {
      var mountTarget = true;
      late StateSetter updateTree;
      final events = <String>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              updateTree = setState;
              if (!mountTarget) {
                return const SizedBox.shrink();
              }
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: DropTarget(
                    onDragEntered: (_) => events.add('enter'),
                    onDragUpdated: (_) => events.add('update'),
                    onDragExited: (_) => events.add('exit'),
                    child: const SizedBox.expand(),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 20, 'y': 20},
      );
      expect(events, <String>['enter']);

      updateTree(() => mountTarget = false);
      await tester.pump();

      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 30, 'y': 30},
      );
      await _sendNativeDropCall('onDragExited');
      expect(events, <String>['enter']);
    });
  });

  group('Edge Cases & Additional Model Parity', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel, null);
    });

    test('FileDropItem cached length and lastModified avoid disk reads',
        () async {
      final ts = DateTime.utc(2026, 1, 1);
      final item = XFile(
        '/nonexistent/cached.bin',
        length: 4096,
        lastModified: ts,
      );
      expect(await item.length(), 4096);
      expect(await item.lastModified(), ts);
    });

    test('DropItemFile.fromData and DropItemDirectory.fromData preserve types',
        () async {
      final fileItem = DropItemFile.fromData(
        Uint8List.fromList(<int>[65, 66, 67]),
        name: 'abc.txt',
      );
      final dirItem = DropItemDirectory.fromData(
        Uint8List(0),
        name: 'bundle',
        children: <FileDropItem>[fileItem],
      );

      expect(fileItem.isDirectory, isFalse);
      expect(await fileItem.readAsString(), 'ABC');
      expect(dirItem.isDirectory, isTrue);
      expect(dirItem.children, hasLength(1));
      expect(dirItem.children.single.name, 'abc.txt');
    });

    test('XTypeGroup uniformTypeIdentifiers maps cleanly to macUTIs', () {
      const group = XTypeGroup(
        label: 'Archives',
        uniformTypeIdentifiers: <String>['public.zip-archive'],
      );
      expect(group.macUTIs, <String>['public.zip-archive']);
      expect(group.uniformTypeIdentifiers, <String>['public.zip-archive']);
      expect(group.allowsAll, isFalse);
    });

    test('openFile and getDirectoryPath accept single-element List responses',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return <String>['/Users/user/list_response'];
      });

      final file = await openFile();
      expect(file?.path, '/Users/user/list_response');

      final dir = await getDirectoryPath();
      expect(dir, '/Users/user/list_response');
    });

    test('getSaveLocation handles plain String and out-of-bounds filter index',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return '/Users/user/plain.txt';
      });
      final fromString = await getSaveLocation();
      expect(fromString?.path, '/Users/user/plain.txt');
      expect(fromString?.activeFilter, isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        return <String, Object?>{
          'path': '/Users/user/out_of_range.txt',
          'activeFilterIndex': 99,
        };
      });
      final outOfRange = await getSaveLocation(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'Text', extensions: <String>['txt']),
        ],
      );
      expect(outOfRange?.path, '/Users/user/out_of_range.txt');
      expect(outOfRange?.activeFilter, isNull);
    });

    test('model toString representations include diagnostic fields', () {
      const item = FileDropItem('/tmp/demo.txt', isDirectory: false);
      const group = XTypeGroup(label: 'Demo', extensions: <String>['txt']);
      const save = FileSaveLocation('/tmp/demo.txt', activeFilter: group);
      const hover = DropEventDetails(
        localPosition: Offset(1, 2),
        globalPosition: Offset(3, 4),
      );
      const done = DropDoneDetails(
        files: <DropItem>[item],
        localPosition: Offset(1, 2),
        globalPosition: Offset(3, 4),
      );

      expect(item.toString(), contains('demo.txt'));
      expect(group.toString(), contains('Demo'));
      expect(save.toString(), contains('/tmp/demo.txt'));
      expect(hover.toString(), contains('Offset(1.0, 2.0)'));
      expect(done.toString(), contains('demo.txt'));
    });
  });

  group('desktop_drop 0.9.2 & cross_file 0.4.x Parity', () {
    late Directory tempDir;

    setUp(() async {
      DesktopDrop.instance.resetForTesting();
      tempDir = await Directory.systemTemp.createTemp('file_drop_092_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('barrels export cross_file 0.4.x and desktop_drop 0.9.2 types', () {
      expect(identical(XEntity, FileDropItem), isTrue);
      expect(identical(XDirectory, DropItemDirectory), isTrue);
      expect(identical(dd_barrel.XEntity, FileDropItem), isTrue);
      expect(identical(dd_barrel.XDirectory, DropItemDirectory), isTrue);
      expect(identical(fs_barrel.XEntity, FileDropItem), isTrue);
      expect(identical(fs_barrel.XDirectory, DropItemDirectory), isTrue);
      expect(identical(dd_barrel.DropFileItem, DropFileItem), isTrue);
      expect(identical(dd_barrel.DropDirectoryItem, DropDirectoryItem), isTrue);
      expect(identical(dd_barrel.DropStringItem, DropStringItem), isTrue);
      expect(identical(dd_barrel.DropItemKind, DropItemKind), isTrue);
      expect(identical(dd_barrel.DropOperation, DropOperation), isTrue);
    });

    test(
        'XFile.fileSystem, XDirectory.fileSystem, uri, exists, writeAsBytes, and list()',
        () async {
      final filePath = '${tempDir.path}${Platform.pathSeparator}created.json';
      final xfile = XFile.fileSystem(path: filePath);
      expect(await xfile.exists(), isFalse);
      expect(xfile.uri, startsWith('file://'));

      final written = await xfile.writeAsBytes(
        Uint8List.fromList(utf8.encode('{"ok":true}')),
      );
      expect(await written.exists(), isTrue);
      expect(await written.readAsString(), '{"ok":true}');

      final fromUri = XFile.fromUri(Uri.file(filePath));
      expect(fromUri.path, filePath);

      final subDir = Directory('${tempDir.path}/child_dir');
      await subDir.create();

      final xdir = XDirectory.fileSystem(path: tempDir.path);
      expect(await xdir.exists(), isTrue);
      final entries = await xdir.list().toList();
      expect(entries, hasLength(2));
      expect(entries.any((XEntity e) => e.name == 'created.json'), isTrue);
      expect(
        entries.any((XEntity e) => e.name == 'child_dir' && e.isDirectory),
        isTrue,
      );
    });

    test(
        'DropFileItem, DropDirectoryItem, and DropStringItem satisfy 0.8.x and 0.9.2 contracts',
        () async {
      final memBytes = Uint8List.fromList(utf8.encode('provider payload'));
      final virtualFile = DropFileItem(
        file: XFile.fromData(memBytes, name: 'report.pdf'),
        name: 'report.pdf',
      );
      expect(virtualFile, isA<DropItemFile>());
      expect(virtualFile.localPath, isNull);
      expect(virtualFile.mimeType, 'application/pdf');
      expect(await virtualFile.file.readAsString(), 'provider payload');
      expect(await virtualFile.readAsBytes(), memBytes);

      final bookmark = Uint8List.fromList(<int>[9, 8, 7]);
      final diskDropFile = DropFileItem.fromPath(
        '/Users/user/banner.webp',
        appleBookmark: bookmark,
        isPromised: true,
      );
      expect(diskDropFile, isA<DropItemFile>());
      expect(diskDropFile.localPath, '/Users/user/banner.webp');
      expect(diskDropFile.mimeType, 'image/webp');
      expect(diskDropFile.appleBookmark, bookmark);
      expect(diskDropFile.extraAppleBookmark, bookmark);
      expect(diskDropFile.isPromised, isTrue);
      expect(diskDropFile.fromPromise, isTrue);

      final dropDir = DropDirectoryItem.fromPath(tempDir.path);
      expect(dropDir, isA<DropItemDirectory>());
      expect(dropDir.directory, isA<XDirectory>());
      expect(dropDir.localPath, tempDir.path);
      expect(dropDir.mimeType, isNull);

      const strItem = DropStringItem(
        mimeType: 'text/plain',
        value: 'https://infradise.com',
      );
      expect(strItem, isA<DropItem>());
      expect(strItem.mimeType, 'text/plain');
      expect(strItem.value, 'https://infradise.com');
      expect(strItem.localPath, isNull);
      expect(await strItem.readAsString(), 'https://infradise.com');

      expect(
        () => DesktopDrop.instance.requestDirectoryAccess(directory: dropDir),
        throwsUnsupportedError,
      );
    });

    test('DropOffer.fromMap and DropItemPreview infer MIME and operations', () {
      final offer = DropOffer.fromMap(const <String, Object?>{
        'files': <Map<String, Object?>>[
          <String, Object?>{
            'name': 'archive.zip',
            'path': '/tmp/archive.zip',
            'isDirectory': false,
          },
          <String, Object?>{
            'name': 'Docs',
            'path': '/tmp/Docs',
            'isDirectory': true,
          },
        ],
        'strings': <Map<String, Object?>>[
          <String, Object?>{'mimeType': 'text/uri-list', 'value': 'file:///a'},
        ],
        'isComplete': true,
        'allowedOperations': <String>['copy', 'link'],
      });

      expect(offer.isComplete, isTrue);
      expect(
        offer.allowedOperations,
        <DropOperation>{DropOperation.copy, DropOperation.link},
      );
      expect(offer.items, hasLength(3));
      expect(offer.items[0].kind, DropItemKind.file);
      expect(offer.items[0].mimeType, 'application/zip');
      expect(offer.items[1].kind, DropItemKind.directory);
      expect(offer.items[1].mimeType, isNull);
      expect(offer.items[2].kind, DropItemKind.string);
      expect(offer.items[2].value, 'file:///a');
    });

    testWidgets(
        'DropTarget supports 0.9.2 onEnter, onMove, onLeave, onDrop, and pattern matching',
        (WidgetTester tester) async {
      final lifecycle = <String>[];
      DragDetails? lastHover;
      DropDetails? receivedDrop;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              height: 160,
              child: DropTarget(
                enabled: true,
                operation: DropOperation.move,
                onEnter: (DragDetails d) {
                  lifecycle.add('enter');
                  lastHover = d;
                },
                onMove: (DragDetails d) {
                  lifecycle.add('move');
                  lastHover = d;
                },
                onLeave: () {
                  lifecycle.add('leave');
                },
                onDrop: (DropDetails details) async {
                  lifecycle.add('drop');
                  receivedDrop = details;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 40, 'y': 30},
      );
      await _sendNativeDropCall(
        'onDragUpdated',
        <String, double>{'x': 80, 'y': 60},
      );
      expect(lifecycle, <String>['enter', 'move']);
      expect(lastHover?.localPosition, const Offset(80, 60));

      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 90.0,
        'y': 70.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/key.pem', 'isDirectory': false},
          <String, Object?>{'path': '/tmp/certs', 'isDirectory': true},
        ],
        'strings': <Map<String, Object?>>[
          <String, Object?>{'mimeType': 'text/plain', 'value': 'snippet'},
        ],
      });

      expect(lifecycle, <String>['enter', 'move', 'leave', 'drop']);
      expect(receivedDrop, isNotNull);
      expect(receivedDrop!.operation, DropOperation.move);
      expect(receivedDrop!.items, hasLength(3));

      final matched = <String>[];
      for (final item in receivedDrop!.items) {
        if (item is DropFileItem) {
          matched.add('file:${item.name}');
        } else if (item is DropDirectoryItem) {
          matched.add('dir:${item.name}');
        } else if (item is DropStringItem) {
          matched.add('str:${item.value}');
        }
      }
      expect(matched, <String>['file:key.pem', 'dir:certs', 'str:snippet']);
    });

    testWidgets(
        'acceptedKinds and onWillAccept rejection fall back to ancestor DropTarget',
        (WidgetTester tester) async {
      final log = <String>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: DropTarget(
                acceptedKinds: const <DropItemKind>{DropItemKind.file},
                onEnter: (_) => log.add('ancestor:enter'),
                onDrop: (DropDetails d) =>
                    log.add('ancestor:drop:${d.items.single.name}'),
                child: Center(
                  child: SizedBox(
                    width: 120,
                    height: 120,
                    child: DropTarget(
                      // Inner target only accepts strings or rejects via onWillAccept.
                      acceptedKinds: const <DropItemKind>{DropItemKind.file},
                      onWillAccept: (DragDetails details) {
                        return details.items.any(
                          (DropItemPreview p) => p.name == 'allowed_inner.txt',
                        );
                      },
                      onEnter: (_) => log.add('inner:enter'),
                      onDrop: (DropDetails d) =>
                          log.add('inner:drop:${d.items.single.name}'),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Hover at center (150, 150) without 'allowed_inner.txt' -> inner rejects,
      // ancestor accepts!
      await _sendNativeDropCall(
        'onDragEntered',
        <String, double>{'x': 150, 'y': 150},
      );
      expect(log, <String>['ancestor:enter']);

      // Drop 'outer_fallback.txt' at center -> inner rejects, ancestor receives drop!
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 150.0,
        'y': 150.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'path': '/tmp/outer_fallback.txt',
            'isDirectory': false,
          },
        ],
      });
      expect(
        log,
        <String>['ancestor:enter', 'ancestor:drop:outer_fallback.txt'],
      );

      // Drop 'allowed_inner.txt' at center -> inner accepts and consumes!
      log.clear();
      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 150.0,
        'y': 150.0,
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'path': '/tmp/allowed_inner.txt',
            'isDirectory': false,
          },
        ],
      });
      expect(log, <String>['inner:drop:allowed_inner.txt']);
    });
  });

  group('Stage 1 Cross-Platform APIs, Mobile SAF Hooks & Drop Sessions', () {
    late Directory tempDir;
    final recordedCalls = <MethodCall>[];

    setUp(() async {
      recordedCalls.clear();
      DesktopDrop.instance.resetForTesting();
      tempDir = await Directory.systemTemp.createTemp('file_drop_stage1_');
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel, null);
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('file_drop and file_selector barrels export cross-platform functions',
        () {
      expect(fs_barrel.saveFile, same(saveFile));
      expect(fs_barrel.openDirectory, same(openDirectory));
      expect(fs_barrel.clearTemporaryFiles, same(clearTemporaryFiles));
    });

    test('saveFile on Desktop writes bytes to chosen path and handles cancel',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final outPath = '${tempDir.path}/desktop_saved.txt';
      final payload = Uint8List.fromList(utf8.encode('Desktop saveFile test!'));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return <String, Object?>{'path': outPath, 'activeFilterIndex': 0};
      });

      final savedPath = await saveFile(
        bytes: payload,
        suggestedName: 'desktop_saved.txt',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'Text', extensions: <String>['txt']),
        ],
        confirmButtonText: 'Save',
      );

      expect(savedPath, outPath);
      expect(recordedCalls.single.method, 'getSaveLocation');
      expect(await File(outPath).readAsBytes(), payload);

      // Verify explicit mimeType synthesizes acceptedTypeGroups when omitted.
      recordedCalls.clear();
      final reportPath = '${tempDir.path}/report.txt';
      final reportBytes = Uint8List.fromList(utf8.encode('Hello, file_drop!'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return <String, Object?>{'path': reportPath, 'activeFilterIndex': 0};
      });

      final savedReport = await saveFile(
        bytes: reportBytes,
        suggestedName: 'report.txt',
        mimeType: 'text/plain',
      );
      expect(savedReport, reportPath);
      expect(await File(reportPath).readAsBytes(), reportBytes);
      final saveLocArgs =
          recordedCalls.single.arguments as Map<Object?, Object?>;
      final synthesizedGroups =
          saveLocArgs['acceptedTypeGroups'] as List<Object?>;
      expect(synthesizedGroups, hasLength(1));
      final firstGroup = synthesizedGroups.single as Map<Object?, Object?>;
      expect(firstGroup['mimeTypes'], <String>['text/plain']);
      expect(firstGroup['extensions'], <String>['txt']);

      // Verify cancellation returns null without touching disk.
      recordedCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return null;
      });

      final cancelled = await saveFile(
        bytes: payload,
        suggestedName: 'cancelled.txt',
      );
      expect(cancelled, isNull);
      expect(recordedCalls.single.method, 'getSaveLocation');
      expect(File('${tempDir.path}/cancelled.txt').existsSync(), isFalse);
    });

    test('saveFile on Android and iOS invokes native saveFile channel method',
        () async {
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

      for (final mobilePlatform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        recordedCalls.clear();
        debugDefaultTargetPlatformOverride = mobilePlatform;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopDrop.channel,
                (MethodCall call) async {
          recordedCalls.add(call);
          return mobilePlatform == TargetPlatform.android
              ? 'content://com.android.externalstorage.documents/document/primary%3Aout.bin'
              : '/private/var/mobile/Containers/Shared/out.bin';
        });

        final saved = await saveFile(
          bytes: payload,
          suggestedName: 'report.txt',
          mimeType: 'text/plain',
          initialDirectory: '/storage',
          confirmButtonText: 'Export',
        );

        expect(saved, isNotNull);
        expect(recordedCalls, hasLength(1));
        expect(recordedCalls.single.method, 'saveFile');
        final args = recordedCalls.single.arguments as Map<Object?, Object?>;
        expect(args['bytes'], payload);
        expect(args['suggestedName'], 'report.txt');
        expect(args['mimeType'], 'text/plain');
        final mobileGroups = args['acceptedTypeGroups'] as List<Object?>;
        expect(mobileGroups, hasLength(1));
        expect(
          (mobileGroups.single as Map<Object?, Object?>)['mimeTypes'],
          <String>['text/plain'],
        );
        expect(args['initialDirectory'], '/storage');
        expect(args['confirmButtonText'], 'Export');
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('openDirectory supports Desktop/iOS paths and Android SAF tree URIs',
        () async {
      // 1. Desktop / iOS delegates to getDirectoryPath and wraps local folder.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final sampleFile = File('${tempDir.path}/inside.txt');
      await sampleFile.writeAsString('inside');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return tempDir.path;
      });

      final iosDir = await openDirectory(confirmButtonText: 'Select');
      expect(recordedCalls.single.method, 'getDirectoryPath');
      expect(iosDir, isA<DropDirectoryItem>());
      expect(iosDir!.localPath, tempDir.path);
      final iosChildren = await iosDir.list().toList();
      expect(iosChildren.map((XEntity e) => e.name), <String>['inside.txt']);

      // 2. Android invokes openDirectory and returns channel-backed SAF dir.
      recordedCalls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        if (call.method == 'openDirectory') {
          return <String, Object?>{
            'uri': 'content://com.android.providers.downloads/tree/raw%3ADocs',
            'name': 'Docs',
            'isContentUri': true,
          };
        }
        if (call.method == 'listDirectory') {
          return <Map<String, Object?>>[
            <String, Object?>{
              'uri':
                  'content://com.android.providers.downloads/document/raw%3ADocs%2Freadme.md',
              'name': 'readme.md',
              'mimeType': 'text/markdown',
              'isDirectory': false,
              'isContentUri': true,
            },
          ];
        }
        return null;
      });

      final androidDir = await openDirectory();
      expect(recordedCalls.first.method, 'openDirectory');
      expect(androidDir, isNotNull);
      expect(androidDir!.name, 'Docs');
      expect(androidDir.localPath, isNull);
      expect(androidDir.isDirectory, isTrue);

      final safChildren = await androidDir.list().toList();
      expect(safChildren, hasLength(1));
      expect(safChildren.single, isA<DropFileItem>());
      expect(safChildren.single.name, 'readme.md');
      expect(safChildren.single.localPath, isNull);
      expect(safChildren.single.mimeType, 'text/markdown');
      debugDefaultTargetPlatformOverride = null;
    });

    test('clearTemporaryFiles invokes channel on Mobile and no-ops on Desktop',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return true;
      });

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await clearTemporaryFiles(), isFalse);
      expect(recordedCalls, isEmpty);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await clearTemporaryFiles(), isTrue);
      expect(recordedCalls, hasLength(1));
      expect(recordedCalls.single.method, 'clearTemporaryFiles');

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await clearTemporaryFiles(), isTrue);
      expect(recordedCalls, hasLength(2));
      debugDefaultTargetPlatformOverride = null;
    });

    test(
        'Android requestDirectoryAccess, listDirectory, statContentUri, and readContentUri',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final fileContent = Uint8List.fromList(utf8.encode('Hello SAF Stream!'));
      const initialUri = 'content://com.example.provider/tree/locked_folder';
      const grantedUri = 'content://com.example.provider/tree/granted_folder';
      const childFileUri =
          'content://com.example.provider/document/granted_folder%2Fnotes.txt';

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        switch (call.method) {
          case 'requestDirectoryAccess':
            return <String, Object?>{
              'uri': grantedUri,
              'name': 'GrantedFolder',
              'isContentUri': true,
            };
          case 'listDirectory':
            return <Map<String, Object?>>[
              <String, Object?>{
                'uri': childFileUri,
                'name': 'notes.txt',
                'mimeType': 'text/plain',
                'isDirectory': false,
                'isContentUri': true,
              },
              <String, Object?>{
                'uri': '$grantedUri%2FSubFolder',
                'name': 'SubFolder',
                'isDirectory': true,
                'isContentUri': true,
              },
            ];
          case 'statContentUri':
            return <String, Object?>{
              'exists': true,
              'length': fileContent.length,
              'lastModified': 1762992000000,
            };
          case 'readContentUri':
            return fileContent;
          default:
            return null;
        }
      });

      final initialDir = DropDirectoryItem(
        directory: XDirectory.fromUri(Uri.parse(initialUri)),
        name: 'LockedFolder',
      );
      expect(initialDir.localPath, isNull);

      final updatedDir = await DesktopDrop.instance.requestDirectoryAccess(
        directory: initialDir,
      );
      expect(recordedCalls.first.method, 'requestDirectoryAccess');
      expect(updatedDir.uri, grantedUri);
      expect(updatedDir.name, 'GrantedFolder');
      expect(updatedDir.localPath, isNull);
      // Verify in-place update on original directory handle as well.
      expect(initialDir.uri, grantedUri);

      final entries = await updatedDir.list().toList();
      expect(entries, hasLength(2));
      final safFile = entries[0] as DropFileItem;
      final safSubDir = entries[1] as DropDirectoryItem;

      expect(safSubDir.isDirectory, isTrue);
      expect(safSubDir.name, 'SubFolder');
      expect(safSubDir.localPath, isNull);

      expect(safFile.localPath, isNull);
      expect(await safFile.exists(), isTrue);
      expect(await safFile.length(), fileContent.length);
      expect(
        await safFile.lastModified(),
        DateTime.fromMillisecondsSinceEpoch(1762992000000),
      );
      expect(await safFile.readAsString(), 'Hello SAF Stream!');

      final slicedChunks = await safFile.openRead(6, 9).toList();
      final slicedBytes = slicedChunks.expand((Uint8List c) => c).toList();
      expect(utf8.decode(slicedBytes), 'SAF');

      final copiedDest = '${tempDir.path}/copied_from_saf.txt';
      await safFile.saveTo(copiedDest);
      expect(await File(copiedDest).readAsString(), 'Hello SAF Stream!');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
        'releaseDropSession waits for async onDrop completion and runs in finally',
        (WidgetTester tester) async {
      final releaseSessions = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        if (call.method == 'releaseDropSession') {
          final args = call.arguments as Map<Object?, Object?>;
          releaseSessions.add(args['sessionId'] as String);
        }
        return null;
      });

      final asyncDropGate = Completer<void>();
      var shouldThrowInOnDrop = false;
      var dropEnteredCallback = false;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: DropTarget(
                onDrop: (DropDetails details) async {
                  dropEnteredCallback = true;
                  await asyncDropGate.future;
                  if (shouldThrowInOnDrop) {
                    throw StateError('Simulated drop handler failure');
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      // 1. Start drop with sessionId while async onDrop is still suspended.
      final dropFuture = _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 50.0,
        'y': 50.0,
        'sessionId': 'session-alpha-01',
        'items': <Map<String, Object?>>[
          <String, Object?>{'path': '/tmp/streamed.bin', 'isDirectory': false},
        ],
      });

      await tester.pump();
      expect(dropEnteredCallback, isTrue);
      // Session MUST NOT be released while onDrop is still awaiting!
      expect(releaseSessions, isEmpty);

      // Complete async onDrop -> releaseDropSession fires immediately afterward!
      asyncDropGate.complete();
      await dropFuture;
      expect(releaseSessions, <String>['session-alpha-01']);

      // 2. Verify releaseDropSession still fires in finally if onDrop throws.
      shouldThrowInOnDrop = true;
      final previousOnError = FlutterError.onError;
      FlutterErrorDetails? capturedError;
      FlutterError.onError = (FlutterErrorDetails details) {
        capturedError = details;
      };
      try {
        await _sendNativeDropCall('onDragDone', <String, Object?>{
          'x': 50.0,
          'y': 50.0,
          'sessionId': 'session-beta-02',
          'items': <Map<String, Object?>>[
            <String, Object?>{'path': '/tmp/error.bin', 'isDirectory': false},
          ],
        });
      } finally {
        FlutterError.onError = previousOnError;
      }

      expect(capturedError, isNotNull);
      expect(
        releaseSessions,
        <String>['session-alpha-01', 'session-beta-02'],
      );
    });
  });

  group('Stage 2 Native Mobile (iOS & Android) Guards & Wire Contracts', () {
    late Directory tempDir;
    final recordedCalls = <MethodCall>[];

    setUp(() async {
      recordedCalls.clear();
      DesktopDrop.instance.resetForTesting();
      tempDir = await Directory.systemTemp.createTemp('file_drop_stage2_');
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel, null);
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'getSaveLocation and getSavePath throw UnsupportedError on iOS and Android',
        () async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return '/should/not/be/called';
      });

      for (final mobile in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        debugDefaultTargetPlatformOverride = mobile;
        await expectLater(
          () => getSaveLocation(suggestedName: 'report.pdf'),
          throwsA(isA<UnsupportedError>()),
        );
        await expectLater(
          () => getSavePath(suggestedName: 'report.pdf'),
          throwsA(isA<UnsupportedError>()),
        );
      }
      expect(recordedCalls, isEmpty);
    });

    test(
        'getDirectoryPaths throws UnsupportedError on Android and succeeds on iOS',
        () async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        return <String>[
          '/private/var/mobile/Containers/Shared/FolderA',
          '/private/var/mobile/Containers/Shared/FolderB',
        ];
      });

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(
        () => getDirectoryPaths(confirmButtonText: 'Select'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(recordedCalls, isEmpty);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final iosFolders = await getDirectoryPaths(confirmButtonText: 'Select');
      expect(recordedCalls, hasLength(1));
      expect(recordedCalls.single.method, 'getDirectoryPaths');
      expect(iosFolders, <String>[
        '/private/var/mobile/Containers/Shared/FolderA',
        '/private/var/mobile/Containers/Shared/FolderB',
      ]);
    });

    test(
        'openFile and openFiles work with cached local paths and swipe-cancel on iOS & Android',
        () async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final cachedA = File('${tempDir.path}/picked_alpha.json');
      final cachedB = File('${tempDir.path}/picked_beta.txt');
      await cachedA.writeAsString('{"ok":true}');
      await cachedB.writeAsString('beta payload');

      for (final mobile in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        recordedCalls.clear();
        debugDefaultTargetPlatformOverride = mobile;

        var simulateCancel = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopDrop.channel,
                (MethodCall call) async {
          recordedCalls.add(call);
          if (call.method == 'openFile') {
            return simulateCancel ? null : cachedA.path;
          }
          if (call.method == 'openFiles') {
            return simulateCancel
                ? <String>[]
                : <String>[cachedA.path, cachedB.path];
          }
          return null;
        });

        final single = await openFile(
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(label: 'JSON', extensions: <String>['json']),
          ],
        );
        expect(single, isNotNull);
        expect(single!.name, 'picked_alpha.json');
        expect(single.localPath, cachedA.path);
        expect(single.mimeType, isNull);
        expect(await single.readAsString(), '{"ok":true}');

        final multi = await openFiles();
        expect(multi, hasLength(2));
        expect(await multi[1].readAsString(), 'beta payload');

        // Simulate swipe-to-dismiss / system Back cancellation.
        simulateCancel = true;
        expect(await openFile(), isNull);
        expect(await openFiles(), isEmpty);
      }
    });

    test(
        'Android chunked readContentUri, writeContentUri, and directory_access_required flow',
        () async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      // 600 KB payload (> 256 KB chunk size) to verify multi-slice SAF streaming.
      final largePayload = Uint8List.fromList(
        List<int>.generate(600 * 1024, (int i) => i % 251),
      );
      Uint8List? writtenBytes;
      var treeGranted = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        recordedCalls.add(call);
        final args = call.arguments as Map<Object?, Object?>?;
        switch (call.method) {
          case 'readContentUri':
            final start = (args?['start'] as int?) ?? 0;
            final end = (args?['end'] as int?) ?? largePayload.length;
            final clampedStart = start.clamp(0, largePayload.length);
            final clampedEnd = end.clamp(clampedStart, largePayload.length);
            return Uint8List.sublistView(
              largePayload,
              clampedStart,
              clampedEnd,
            );
          case 'writeContentUri':
            writtenBytes = args?['bytes'] as Uint8List?;
            return null;
          case 'listDirectory':
            if (!treeGranted) {
              throw PlatformException(
                code: 'directory_access_required',
                message: 'Directory access permission is required on Android.',
              );
            }
            return <Map<String, Object?>>[
              <String, Object?>{
                'uri': 'content://com.android.externalstorage/document/big.bin',
                'name': 'big.bin',
                'mimeType': 'application/octet-stream',
                'isDirectory': false,
                'isContentUri': true,
              },
            ];
          case 'requestDirectoryAccess':
            treeGranted = true;
            return <String, Object?>{
              'uri': 'content://com.android.externalstorage/tree/Unlocked',
              'name': 'Unlocked',
              'isContentUri': true,
            };
          default:
            return null;
        }
      });

      final droppedSafDir = DropDirectoryItem(
        directory: XDirectory.fromUri(
          Uri.parse('content://com.android.externalstorage/document/LockedDir'),
        ),
        name: 'LockedDir',
      );

      // 1. Listing without tree access surfaces `directory_access_required`.
      await expectLater(
        () => droppedSafDir.list().toList(),
        throwsA(
          isA<PlatformException>().having(
            (PlatformException e) => e.code,
            'code',
            'directory_access_required',
          ),
        ),
      );

      // 2. Requesting directory access upgrades the handle and unlocks listing.
      await DesktopDrop.instance.requestDirectoryAccess(
        directory: droppedSafDir,
      );
      final children = await droppedSafDir.list().toList();
      expect(children, hasLength(1));
      final bigFile = children.single as DropFileItem;

      // 3. Streaming 600 KB executes 3 chunked `readContentUri` calls (256 KB + 256 KB + 88 KB).
      recordedCalls.clear();
      final streamedBuilder = BytesBuilder(copy: false);
      await for (final chunk in bigFile.openRead()) {
        streamedBuilder.add(chunk);
      }
      final readCalls = recordedCalls
          .where((MethodCall c) => c.method == 'readContentUri')
          .toList();
      expect(readCalls, hasLength(3));
      expect(streamedBuilder.takeBytes(), largePayload);

      // 4. Writing bytes back to a writable SAF content URI invokes `writeContentUri`.
      final outPayload = Uint8List.fromList(<int>[9, 8, 7, 6]);
      await bigFile.writeAsBytes(outPayload);
      expect(writtenBytes, outPayload);
    });

    testWidgets(
        'iOS UIDropInteraction bookmark & session contract works end-to-end',
        (WidgetTester tester) async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final stagedDropFile = File('${tempDir.path}/ipad_splitview.txt')
        ..writeAsStringSync('Dropped from Files.app');
      final bookmarkBytes = Uint8List.fromList(<int>[0x62, 0x6D, 0x72, 0x6B]);
      final releasedSessions = <String>[];
      var bookmarkStarted = false;
      var bookmarkStopped = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopDrop.channel,
              (MethodCall call) async {
        if (call.method == 'startAccessingSecurityScopedResource') {
          bookmarkStarted = true;
          return true;
        }
        if (call.method == 'stopAccessingSecurityScopedResource') {
          bookmarkStopped = true;
          return true;
        }
        if (call.method == 'releaseDropSession') {
          final args = call.arguments as Map<Object?, Object?>;
          releasedSessions.add(args['sessionId'] as String);
          return null;
        }
        return null;
      });

      DropDetails? capturedDrop;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              height: 240,
              child: DropTarget(
                onDrop: (DropDetails details) async {
                  capturedDrop = details;
                  final first = details.items.first as DropFileItem;
                  final bookmark = first.extraAppleBookmark!;
                  await DesktopDrop.instance
                      .startAccessingSecurityScopedResource(bookmark: bookmark);
                  await DesktopDrop.instance
                      .stopAccessingSecurityScopedResource(bookmark: bookmark);
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      await _sendNativeDropCall('onDragDone', <String, Object?>{
        'x': 80.0,
        'y': 90.0,
        'sessionId': 'ios-drop-session-99',
        'rawText': 'https://infradise.com',
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'path': stagedDropFile.path,
            'name': 'ipad_splitview.txt',
            'mimeType': 'text/plain',
            'isDirectory': false,
            'appleBookmark': bookmarkBytes,
          },
          <String, Object?>{
            'kind': 'string',
            'mimeType': 'text/uri-list',
            'value': 'https://infradise.com',
          },
        ],
      });

      expect(capturedDrop, isNotNull);
      expect(capturedDrop!.items, hasLength(2));
      expect(capturedDrop!.rawText, 'https://infradise.com');
      expect(bookmarkStarted, isTrue);
      expect(bookmarkStopped, isTrue);
      expect(releasedSessions, <String>['ios-drop-session-99']);
    });
  });
}
