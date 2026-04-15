import 'dart:io';
import 'package:path/path.dart' as p;

class AgentTools {
  final String baseDir;

  AgentTools({required this.baseDir});

  /// Resolves a relative path and verifies it stays within baseDir.
  String? _safePath(String relativePath) {
    final resolved = p.normalize(p.join(baseDir, relativePath));
    if (!resolved.startsWith(p.normalize(baseDir))) return null;
    return resolved;
  }

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'read_file':
        return _readFile(args['path'] as String);
      case 'write_file':
        return _writeFile(args['path'] as String, args['content'] as String);
      case 'list_directory':
        return _listDirectory(args['path'] as String);
      case 'create_directory':
        return _createDirectory(args['path'] as String);
      case 'search_files':
        return _searchFiles(args['query'] as String);
      case 'move_file':
        return _moveFile(args['from'] as String, args['to'] as String);
      default:
        return 'unknown tool: $toolName';
    }
  }

  Future<String> _readFile(String path) async {
    final safe = _safePath(path);
    if (safe == null) return 'access denied';
    final f = File(safe);
    if (!await f.exists()) return 'not found: $path';
    return f.readAsString();
  }

  Future<String> _writeFile(String path, String content) async {
    final safe = _safePath(path);
    if (safe == null) return 'access denied';
    await Directory(p.dirname(safe)).create(recursive: true);
    await File(safe).writeAsString(content);
    return 'ok';
  }

  Future<String> _listDirectory(String path) async {
    final safe = _safePath(path);
    if (safe == null) return 'access denied';
    final dir = Directory(safe);
    if (!await dir.exists()) return 'not found: $path';
    final entries = await dir.list().map((e) => p.basename(e.path)).toList();
    if (entries.isEmpty) return '(empty)';
    return entries.join('\n');
  }

  Future<String> _createDirectory(String path) async {
    final safe = _safePath(path);
    if (safe == null) return 'access denied';
    await Directory(safe).create(recursive: true);
    return 'ok';
  }

  Future<String> _searchFiles(String query) async {
    final dir = Directory(baseDir);
    if (!await dir.exists()) return 'no results';
    final results = <String>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.md')) {
        final contents = await entity.readAsString();
        if (contents.toLowerCase().contains(query.toLowerCase())) {
          final relative = p.relative(entity.path, from: baseDir);
          final excerpt = _excerpt(contents, query);
          results.add('${relative.replaceAll('\\', '/')}: $excerpt');
        }
      }
    }
    if (results.isEmpty) return 'no results for: $query';
    return results.join('\n');
  }

  String _excerpt(String contents, String query) {
    final idx = contents.toLowerCase().indexOf(query.toLowerCase());
    final start = (idx - 40).clamp(0, contents.length);
    final end = (idx + 80).clamp(0, contents.length);
    return '...${contents.substring(start, end)}...';
  }

  Future<String> _moveFile(String from, String to) async {
    final safeFrom = _safePath(from);
    final safeTo = _safePath(to);
    if (safeFrom == null || safeTo == null) return 'access denied';
    final f = File(safeFrom);
    if (!await f.exists()) return 'not found: $from';
    await Directory(p.dirname(safeTo)).create(recursive: true);
    await f.rename(safeTo);
    return 'ok';
  }
}
