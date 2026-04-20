import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_gemma/flutter_gemma.dart';

class FilesystemTools {
  final String baseDir;

  FilesystemTools({required this.baseDir});

  static List<Tool> get toolDefinitions => const [
    Tool(
      name: 'read_file',
      description: 'Read the contents of a file at the given path.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Path relative to ispy root'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'write_file',
      description: 'Write content to a file, creating it and any parent directories.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Path relative to ispy root'},
          'content': {'type': 'string', 'description': 'File content to write'},
        },
        'required': ['path', 'content'],
      },
    ),
    Tool(
      name: 'list_dir',
      description: 'List files and folders in a directory.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Directory path relative to ispy root'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'search_files',
      description: 'Search all markdown files for a keyword. Returns matching excerpts.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search term'},
        },
        'required': ['query'],
      },
    ),
  ];

  Future<Map<String, dynamic>> execute(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'read_file':
        return {'result': await _read(args['path'] as String)};
      case 'write_file':
        return {'result': await _write(args['path'] as String, args['content'] as String)};
      case 'list_dir':
        return {'result': await _list(args['path'] as String)};
      case 'search_files':
        return {'result': await _search(args['query'] as String)};
      default:
        return {'error': 'unknown tool: $name'};
    }
  }

  String? _safe(String rel) {
    final abs = p.normalize(p.join(baseDir, rel));
    return abs.startsWith(p.normalize(baseDir)) ? abs : null;
  }

  Future<String> _read(String path) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    final f = File(abs);
    return await f.exists() ? await f.readAsString() : 'not found: $path';
  }

  Future<String> _write(String path, String content) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    await Directory(p.dirname(abs)).create(recursive: true);
    await File(abs).writeAsString(content);
    return 'ok';
  }

  Future<String> _list(String path) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    final dir = Directory(abs);
    if (!await dir.exists()) return 'not found: $path';
    final names = await dir.list().map((e) => p.basename(e.path)).toList();
    return names.isEmpty ? '(empty)' : names.join('\n');
  }

  Future<String> _search(String query) async {
    final results = <String>[];
    final dir = Directory(baseDir);
    if (!await dir.exists()) return 'no results';
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.md')) {
        final contents = await entity.readAsString();
        if (contents.toLowerCase().contains(query.toLowerCase())) {
          final rel = p.relative(entity.path, from: baseDir).replaceAll('\\', '/');
          final idx = contents.toLowerCase().indexOf(query.toLowerCase());
          final start = (idx - 40).clamp(0, contents.length);
          final end = (idx + 80).clamp(0, contents.length);
          results.add('$rel: ...${contents.substring(start, end)}...');
        }
      }
    }
    return results.isEmpty ? 'no results for: $query' : results.join('\n');
  }
}
