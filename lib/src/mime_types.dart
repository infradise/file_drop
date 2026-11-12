/// Infers a standard MIME type from [name] or [path] when [provided] is empty.
///
/// Uses a zero-dependency extension table without reading file bytes.
String? inferMimeTypeFromPath(
  String? provided,
  String? name, [
  String? path,
]) {
  if (provided != null && provided.isNotEmpty) {
    return provided;
  }
  final candidate = (name != null && name.isNotEmpty) ? name : (path ?? '');
  final dotIndex = candidate.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex == candidate.length - 1) {
    return null;
  }
  final ext = candidate.substring(dotIndex + 1).toLowerCase();
  return _extensionMimeTypes[ext];
}

/// Extracts the base filename or directory name from [rawPath] across both
/// POSIX (`/`) and Windows (`\`) path separators.
String extractPathBasename(String rawPath) {
  if (rawPath.isEmpty) {
    return '';
  }
  var end = rawPath.length;
  while (end > 0) {
    final code = rawPath.codeUnitAt(end - 1);
    if (code == 0x2F /* / */ || code == 0x5C /* \ */) {
      end--;
    } else {
      break;
    }
  }
  if (end == 0) {
    return '';
  }
  var lastSeparator = -1;
  for (var i = end - 1; i >= 0; i--) {
    final code = rawPath.codeUnitAt(i);
    if (code == 0x2F /* / */ || code == 0x5C /* \ */) {
      lastSeparator = i;
      break;
    }
  }
  return rawPath.substring(lastSeparator + 1, end);
}

const Map<String, String> _extensionMimeTypes = <String, String>{
  'aac': 'audio/aac',
  'avi': 'video/x-msvideo',
  'avif': 'image/avif',
  'bmp': 'image/bmp',
  'bz2': 'application/x-bzip2',
  'c': 'text/x-c',
  'cc': 'text/x-c++src',
  'cpp': 'text/x-c++src',
  'css': 'text/css',
  'csv': 'text/csv',
  'dart': 'text/x-dart',
  'db': 'application/vnd.sqlite3',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'flac': 'audio/flac',
  'gif': 'image/gif',
  'go': 'text/x-go',
  'gz': 'application/gzip',
  'h': 'text/x-chdr',
  'heic': 'image/heic',
  'hpp': 'text/x-c++hdr',
  'htm': 'text/html',
  'html': 'text/html',
  'ico': 'image/x-icon',
  'ini': 'text/plain',
  'java': 'text/x-java-source',
  'jpeg': 'image/jpeg',
  'jpg': 'image/jpeg',
  'js': 'text/javascript',
  'json': 'application/json',
  'kt': 'text/x-kotlin',
  'log': 'text/plain',
  'm4a': 'audio/mp4',
  'md': 'text/markdown',
  'mjs': 'text/javascript',
  'mkv': 'video/x-matroska',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'mp4': 'video/mp4',
  'ogg': 'audio/ogg',
  'pdf': 'application/pdf',
  'png': 'image/png',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'py': 'text/x-python',
  'rar': 'application/vnd.rar',
  'rs': 'text/rust',
  'rtf': 'application/rtf',
  'sh': 'application/x-sh',
  'sqlite': 'application/vnd.sqlite3',
  'svg': 'image/svg+xml',
  'swift': 'text/x-swift',
  'tar': 'application/x-tar',
  'tgz': 'application/gzip',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'toml': 'application/toml',
  'ts': 'video/mp2t',
  'txt': 'text/plain',
  'wasm': 'application/wasm',
  'wav': 'audio/wav',
  'webm': 'video/webm',
  'webp': 'image/webp',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xml': 'application/xml',
  'xz': 'application/x-xz',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'zip': 'application/zip',
  '7z': 'application/x-7z-compressed',
};
