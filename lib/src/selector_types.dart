import 'package:flutter/foundation.dart' show immutable;

/// A group of accepted file types for native open and save dialogs.
///
/// Mirrors `XTypeGroup` from `file_selector` with zero external dependencies.
@immutable
class XTypeGroup {
  /// Creates a file type filter group.
  ///
  /// When all filter lists are `null` or empty, [allowsAll] evaluates to
  /// `true` and any file type is permitted.
  const XTypeGroup({
    this.label,
    List<String>? extensions,
    this.mimeTypes,
    List<String>? macUTIs,
    List<String>? uniformTypeIdentifiers,
    this.webWildCards,
  })  : _extensions = extensions,
        macUTIs = macUTIs ?? uniformTypeIdentifiers;

  /// Human-readable label shown in native filter dropdowns (for example,
  /// `"Images"`).
  final String? label;

  final List<String>? _extensions;

  /// Allowed file extensions with any leading `.` or `*.` normalized away
  /// (for example, `['png', 'jpg']`).
  List<String>? get extensions => _normalizeExtensions(_extensions);

  /// Allowed MIME types (for example, `['image/png', 'application/pdf']`).
  final List<String>? mimeTypes;

  /// Allowed Apple Uniform Type Identifiers on macOS (for example,
  /// `['public.image', 'public.plain-text']`).
  final List<String>? macUTIs;

  /// Alias for [macUTIs] matching `file_selector_platform_interface`.
  List<String>? get uniformTypeIdentifiers => macUTIs;

  /// Allowed web wildcard patterns retained for `file_selector` API parity.
  final List<String>? webWildCards;

  /// Whether this group imposes no type restrictions and allows all files.
  bool get allowsAll {
    final normalized = extensions;
    return (normalized == null || normalized.isEmpty) &&
        (mimeTypes == null || mimeTypes!.isEmpty) &&
        (macUTIs == null || macUTIs!.isEmpty) &&
        (webWildCards == null || webWildCards!.isEmpty);
  }

  /// Alias for [allowsAll] matching `file_selector_platform_interface`.
  bool get allowsAny => allowsAll;

  /// Serializes this filter group into a platform channel map.
  Map<String, dynamic> toMap() {
    final normalizedExtensions = extensions;
    return <String, dynamic>{
      'label': label,
      'extensions': normalizedExtensions,
      'mimeTypes': mimeTypes,
      'macUTIs': macUTIs,
      'uniformTypeIdentifiers': macUTIs,
      'webWildCards': webWildCards,
    };
  }

  /// Alias for [toMap] matching `file_selector_platform_interface`.
  Map<String, dynamic> toJSON() => toMap();

  static List<String>? _normalizeExtensions(List<String>? rawExtensions) {
    if (rawExtensions == null) {
      return null;
    }
    return rawExtensions
        .map((String ext) {
          var cleaned = ext.trim();
          if (cleaned.startsWith('*.')) {
            cleaned = cleaned.substring(2);
          } else if (cleaned.startsWith('.')) {
            cleaned = cleaned.substring(1);
          }
          return cleaned;
        })
        .where((String ext) => ext.isNotEmpty)
        .toList(growable: false);
  }

  @override
  String toString() =>
      'XTypeGroup(label: $label, extensions: $extensions, mimeTypes: $mimeTypes, macUTIs: $macUTIs)';
}

/// Result returned from a native file save dialog via `getSaveLocation`.
@immutable
class FileSaveLocation {
  /// Creates a [FileSaveLocation] with the chosen [path] and optional
  /// [activeFilter].
  const FileSaveLocation(this.path, {this.activeFilter});

  /// Full filesystem path chosen by the user.
  final String path;

  /// Filter group selected in the save dialog, if reported by the platform.
  final XTypeGroup? activeFilter;

  @override
  String toString() =>
      'FileSaveLocation(path: $path, activeFilter: $activeFilter)';
}
