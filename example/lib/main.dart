import 'dart:convert';
import 'dart:typed_data';

import 'package:file_drop/file_drop.dart';
import 'package:flutter/widgets.dart';

void main() {
  runApp(const FileDropExampleApp());
}

/// Zero-dependency cross-platform testbed app showcasing native/browser dialogs
/// and multi-zone `DropTarget`s using pure `package:flutter/widgets.dart`.
class FileDropExampleApp extends StatelessWidget {
  /// Creates the example application.
  const FileDropExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'file_drop Testbed',
      color: const Color(0xFF2563EB),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
        return PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (BuildContext context, _, __) => builder(context),
        );
      },
      home: const FileDropHomePage(),
    );
  }
}

/// Main screen demonstrating all dialog actions and interactive drop targets.
class FileDropHomePage extends StatefulWidget {
  /// Creates the [FileDropHomePage].
  const FileDropHomePage({super.key});

  @override
  State<FileDropHomePage> createState() => _FileDropHomePageState();
}

class _FileDropHomePageState extends State<FileDropHomePage> {
  String _dialogResultSummary = 'No dialog action invoked yet.';
  final List<FileDropItem> _zoneAItems = <FileDropItem>[];
  final List<FileDropItem> _zoneBItems = <FileDropItem>[];
  bool _zoneBEnabled = true;

  static const List<XTypeGroup> _demoTypeGroups = <XTypeGroup>[
    XTypeGroup(
      label: 'Documents & Text',
      extensions: <String>['txt', 'md', 'json', 'pdf'],
      mimeTypes: <String>['text/plain', 'application/json', 'application/pdf'],
      macUTIs: <String>['public.plain-text', 'public.json', 'com.adobe.pdf'],
    ),
    XTypeGroup(
      label: 'Images',
      extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
      mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
      macUTIs: <String>['public.image'],
    ),
  ];

  Future<void> _pickSingleFile() async {
    final file = await openFile(
      acceptedTypeGroups: _demoTypeGroups,
      confirmButtonText: 'Select File',
    );
    if (!mounted) {
      return;
    }
    if (file == null) {
      setState(() => _dialogResultSummary = 'Open File: Cancelled');
      return;
    }
    final size = await file.length();
    if (!mounted) {
      return;
    }
    setState(() {
      _dialogResultSummary = 'Opened File: ${file.name} ($size bytes)\n'
          'Location: ${file.localPath ?? file.path}';
    });
  }

  Future<void> _pickMultipleFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: _demoTypeGroups,
      confirmButtonText: 'Select Files',
    );
    if (!mounted) {
      return;
    }
    if (files.isEmpty) {
      setState(() => _dialogResultSummary = 'Open Multiple: Cancelled');
      return;
    }
    setState(() {
      _dialogResultSummary = 'Opened ${files.length} file(s):\n'
          '${files.map((XFile f) => '• ${f.name} (${f.localPath ?? f.path})').join('\n')}';
    });
  }

  Future<void> _chooseSaveFile() async {
    final sampleBytes = Uint8List.fromList(
      utf8.encode(
        'file_drop v1.0.0 sample export\nCopyright 2026 Infradise Inc.\n',
      ),
    );
    final savedDestination = await saveFile(
      bytes: sampleBytes,
      acceptedTypeGroups: _demoTypeGroups,
      suggestedName: 'export_report.txt',
      confirmButtonText: 'Save Report',
    );
    if (!mounted) {
      return;
    }
    if (savedDestination == null) {
      setState(() => _dialogResultSummary = 'Save File: Cancelled');
      return;
    }
    setState(() {
      _dialogResultSummary =
          'Saved ${sampleBytes.length} bytes to: $savedDestination';
    });
  }

  Future<void> _chooseSaveLocation() async {
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: _demoTypeGroups,
        suggestedName: 'export_report.txt',
        confirmButtonText: 'Choose Path',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary = location == null
            ? 'Save Location: Cancelled'
            : 'Save Location: ${location.path}';
      });
    } on UnsupportedError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary = 'Save Location: ${error.message}';
      });
    }
  }

  Future<void> _pickDirectory() async {
    try {
      final directoryPath = await getDirectoryPath(
        confirmButtonText: 'Choose Folder',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary = directoryPath == null
            ? 'Pick Directory: Cancelled'
            : 'Directory Path: $directoryPath';
      });
    } on UnsupportedError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary = 'Pick Directory: ${error.message}';
      });
    }
  }

  Future<void> _openDirectoryAndList() async {
    try {
      final directory = await openDirectory(
        confirmButtonText: 'Open Folder',
      );
      if (!mounted) {
        return;
      }
      if (directory == null) {
        setState(() => _dialogResultSummary = 'Open Directory: Cancelled');
        return;
      }
      final entries = await directory.list().toList();
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary =
            'Opened Directory: ${directory.name} (${entries.length} item(s))\n'
            'Location: ${directory.localPath ?? directory.path}';
      });
    } on UnsupportedError catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogResultSummary = 'Open Directory: ${error.message}';
      });
    }
  }

  Future<void> _clearTempCache() async {
    final cleared = await clearTemporaryFiles();
    if (!mounted) {
      return;
    }
    setState(() {
      _dialogResultSummary = cleared
          ? 'Temporary Cache: Cleared native picker/drop temp files.'
          : 'Temporary Cache: Nothing to clear on this platform.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF8FAFC),
      child: SafeArea(
        child: DefaultTextStyle(
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF0F172A),
            fontFamily: '.AppleSystemUIFont',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFFFFF),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'file_drop — Zero-Dependency Testbed',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _ActionButton(
                      label: _zoneBEnabled
                          ? 'Zone B: Enabled'
                          : 'Zone B: Disabled',
                      backgroundColor: _zoneBEnabled
                          ? const Color(0xFF059669)
                          : const Color(0xFF64748B),
                      onPressed: () =>
                          setState(() => _zoneBEnabled = !_zoneBEnabled),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[
                          _ActionButton(
                            label: 'Open File',
                            onPressed: _pickSingleFile,
                          ),
                          _ActionButton(
                            label: 'Open Multiple',
                            onPressed: _pickMultipleFiles,
                          ),
                          _ActionButton(
                            label: 'Save File',
                            onPressed: _chooseSaveFile,
                          ),
                          _ActionButton(
                            label: 'Save Location',
                            onPressed: _chooseSaveLocation,
                          ),
                          _ActionButton(
                            label: 'Pick Directory',
                            onPressed: _pickDirectory,
                          ),
                          _ActionButton(
                            label: 'Open Directory',
                            onPressed: _openDirectoryAndList,
                          ),
                          _ActionButton(
                            label: 'Clear Temp',
                            backgroundColor: const Color(0xFF475569),
                            onPressed: _clearTempCache,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFFFF),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: Text(_dialogResultSummary),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: _InteractiveDropZone(
                                title: 'Drop Zone A (Always Enabled)',
                                enabled: true,
                                accentColor: const Color(0xFF2563EB),
                                items: _zoneAItems,
                                onItemsDropped: (List<FileDropItem> dropped) {
                                  setState(() {
                                    _zoneAItems
                                      ..clear()
                                      ..addAll(dropped);
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _InteractiveDropZone(
                                title: 'Drop Zone B (Toggleable)',
                                enabled: _zoneBEnabled,
                                accentColor: const Color(0xFF059669),
                                items: _zoneBItems,
                                onItemsDropped: (List<FileDropItem> dropped) {
                                  setState(() {
                                    _zoneBItems
                                      ..clear()
                                      ..addAll(dropped);
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onPressed,
    this.backgroundColor = const Color(0xFF2563EB),
  });

  final String label;
  final VoidCallback onPressed;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _InteractiveDropZone extends StatefulWidget {
  const _InteractiveDropZone({
    required this.title,
    required this.enabled,
    required this.accentColor,
    required this.items,
    required this.onItemsDropped,
  });

  final String title;
  final bool enabled;
  final Color accentColor;
  final List<FileDropItem> items;
  final ValueChanged<List<FileDropItem>> onItemsDropped;

  @override
  State<_InteractiveDropZone> createState() => _InteractiveDropZoneState();
}

class _InteractiveDropZoneState extends State<_InteractiveDropZone> {
  bool _hovering = false;
  Offset? _localOffset;
  Offset? _globalOffset;

  @override
  Widget build(BuildContext context) {
    final borderColor = !widget.enabled
        ? const Color(0xFFCBD5E1)
        : (_hovering ? widget.accentColor : const Color(0xFF94A3B8));
    final fillColor = !widget.enabled
        ? const Color(0xFFF1F5F9)
        : (_hovering
            ? widget.accentColor.withValues(alpha: 0.10)
            : const Color(0xFFFFFFFF));

    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (DropEventDetails details) {
        setState(() {
          _hovering = true;
          _localOffset = details.localPosition;
          _globalOffset = details.globalPosition;
        });
      },
      onDragUpdated: (DropEventDetails details) {
        setState(() {
          _localOffset = details.localPosition;
          _globalOffset = details.globalPosition;
        });
      },
      onDragExited: (DropEventDetails details) {
        setState(() {
          _hovering = false;
          _localOffset = null;
          _globalOffset = null;
        });
      },
      onDragDone: (DropDoneDetails details) {
        widget.onItemsDropped(details.files);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: borderColor,
            width: _hovering ? 2.5 : 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.enabled
                    ? const Color(0xFF0F172A)
                    : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              !widget.enabled
                  ? 'Disabled (enable: false)'
                  : _hovering
                      ? 'Hovering — local: (${_localOffset?.dx.toStringAsFixed(1)}, ${_localOffset?.dy.toStringAsFixed(1)}) | '
                          'global: (${_globalOffset?.dx.toStringAsFixed(1)}, ${_globalOffset?.dy.toStringAsFixed(1)})'
                      : 'Drag files, folders, or text snippets here.',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: widget.items.isEmpty
                  ? const Center(
                      child: Text(
                        'No items dropped yet.',
                        style: TextStyle(color: Color(0xFF94A3B8)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: widget.items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (BuildContext context, int index) {
                        final item = widget.items[index];
                        final isString = item is DropStringItem;
                        final isDir = !isString &&
                            (item is DropItemDirectory || item.isDirectory);
                        final titleText =
                            isString ? 'String (${item.mimeType})' : item.name;
                        final subtitleText = isString
                            ? item.value
                            : (item.localPath ?? item.path);
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      titleText,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitleText,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isString
                                      ? const Color(0xFFDCFCE7)
                                      : (isDir
                                          ? const Color(0xFFFEF3C7)
                                          : const Color(0xFFDBEAFE)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  isString
                                      ? 'String'
                                      : (isDir ? 'Directory' : 'File'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isString
                                        ? const Color(0xFF166534)
                                        : (isDir
                                            ? const Color(0xFF92400E)
                                            : const Color(0xFF1E40AF)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
