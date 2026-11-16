import 'dart:convert';

import 'package:file_drop/file_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _sendDropChannelCall(String method, [Object? arguments]) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopDrop.instance.resetForTesting();
  });

  test('in-memory XFile / DropStringItem / DropOffer work without dart:io',
      () async {
    final bytes = Uint8List.fromList(utf8.encode('wasm-ready payload'));
    final file = XFile.fromData(bytes, name: 'sample.json');
    final dropItem = DropFileItem(file: file, name: 'sample.json');
    expect(dropItem.mimeType, 'application/json');
    expect(await file.length(), bytes.length);
    expect(await file.readAsString(), 'wasm-ready payload');

    final chunks = await file.openRead(0, 10).toList();
    expect(
        utf8.decode(chunks.expand((Uint8List c) => c).toList()), 'wasm-ready');
  });

  testWidgets(
      'inactive IndexedStack tabs, hidden Visibility, Offstage, ClipRect, and ModalBarrier block background DropTargets',
      (WidgetTester tester) async {
    final events = <String>[];
    var activeTab = 1;
    var showModal = false;
    late StateSetter rebuild;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return Stack(
              children: <Widget>[
                // Tabbed workspace using pure IndexedStack (NO manual TickerMode wrapper!)
                Positioned(
                  left: 0,
                  top: 0,
                  width: 300,
                  height: 300,
                  child: IndexedStack(
                    index: activeTab,
                    children: <Widget>[
                      DropTarget(
                        onEnter: (_) => events.add('tab0_r2:enter'),
                        onLeave: () => events.add('tab0_r2:leave'),
                        onDrop: (_) => events.add('tab0_r2:drop'),
                        child: const SizedBox.expand(),
                      ),
                      DropTarget(
                        acceptedKinds: const <DropItemKind>{
                          DropItemKind.file,
                          DropItemKind.string,
                        },
                        onEnter: (_) => events.add('tab1_editor:enter'),
                        onLeave: () => events.add('tab1_editor:leave'),
                        onDrop: (DropDetails d) {
                          final item = d.items.single;
                          if (item is DropStringItem) {
                            events.add('tab1_editor:str:${item.value}');
                          } else {
                            events.add('tab1_editor:file:${item.name}');
                          }
                        },
                        child: const SizedBox.expand(),
                      ),
                    ],
                  ),
                ),
                // Clipped DropTarget at x: 320..420, y: 0..100 whose child overflows to y: 250
                Positioned(
                  left: 320,
                  top: 0,
                  width: 100,
                  height: 100,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 250,
                      maxHeight: 250,
                      child: SizedBox(
                        width: 100,
                        height: 250,
                        child: DropTarget(
                          onDrop: (_) => events.add('clipped:drop'),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showModal) ...<Widget>[
                  // Opaque modal barrier blocking everything behind it
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Positioned(
                    left: 40,
                    top: 40,
                    width: 160,
                    height: 120,
                    child: DropTarget(
                      onDrop: (_) => events.add('modal_dialog:drop'),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );

    // 1. Dropping at (100, 100) while activeTab == 1 hits ONLY tab1_editor, NEVER hidden tab0_r2!
    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 100.0,
      'y': 100.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{'path': '/tmp/doc.txt', 'isDirectory': false},
      ],
    });
    expect(events, <String>['tab1_editor:file:doc.txt']);
    events.clear();

    // Switch IndexedStack to tab 0 -> hits ONLY tab0_r2, then switch back to tab 1!
    rebuild(() => activeTab = 0);
    await tester.pump();
    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 100.0,
      'y': 100.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{'path': '/tmp/upload.bin', 'isDirectory': false},
      ],
    });
    expect(events, <String>['tab0_r2:drop']);
    events.clear();
    rebuild(() => activeTab = 1);
    await tester.pump();

    // 2. Desktop string/URI hover + drop on tab1_editor
    await _sendDropChannelCall('onDragEntered', <String, Object?>{
      'x': 100.0,
      'y': 100.0,
      'offer': <String, Object?>{
        'items': const <Object?>[],
        'strings': const <Map<String, Object?>>[
          <String, Object?>{'mimeType': 'text/uri-list'},
        ],
        'isComplete': false,
      },
    });
    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 100.0,
      'y': 100.0,
      'rawText': 'https://keyscope.dev',
      'items': const <Map<String, Object?>>[
        <String, Object?>{
          'kind': 'string',
          'mimeType': 'text/uri-list',
          'value': 'https://keyscope.dev',
        },
      ],
    });
    expect(
      events,
      <String>[
        'tab1_editor:enter',
        'tab1_editor:leave',
        'tab1_editor:str:https://keyscope.dev',
      ],
    );
    events.clear();

    // 3. Dropping outside ClipRect bounds (350, 180) is blocked; inside (350, 50) succeeds!
    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 350.0,
      'y': 180.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{
          'path': '/tmp/outside_clip.txt',
          'isDirectory': false
        },
      ],
    });
    expect(events, isEmpty);

    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 350.0,
      'y': 50.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{'path': '/tmp/inside_clip.txt', 'isDirectory': false},
      ],
    });
    expect(events, <String>['clipped:drop']);
    events.clear();

    // 4. Open modal barrier -> background tab1_editor at (250, 250) is blocked, modal_dialog at (80, 80) receives drop!
    rebuild(() => showModal = true);
    await tester.pump();

    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 250.0,
      'y': 250.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{'path': '/tmp/blocked_bg.txt', 'isDirectory': false},
      ],
    });
    expect(events, isEmpty);

    await _sendDropChannelCall('onDragDone', <String, Object?>{
      'x': 80.0,
      'y': 80.0,
      'items': <Map<String, Object?>>[
        <String, Object?>{'path': '/tmp/modal_ok.txt', 'isDirectory': false},
      ],
    });
    expect(events, <String>['modal_dialog:drop']);
  });
}
