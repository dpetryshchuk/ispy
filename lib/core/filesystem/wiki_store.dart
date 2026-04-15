import 'dart:io';
import 'package:path/path.dart' as p;

class WikiNode {
  final String path; // relative to wiki/, e.g. 'places/home'
  final String title;
  WikiNode({required this.path, required this.title});
}

class WikiEdge {
  final String from;
  final String to;
  WikiEdge({required this.from, required this.to});
}

class WikiGraph {
  final List<WikiNode> nodes;
  final List<WikiEdge> edges;
  WikiGraph({required this.nodes, required this.edges});
}

class WikiStore {
  final String baseDir;

  WikiStore({required this.baseDir});

  String get _wikiDir => p.join(baseDir, 'wiki');

  Future<String> readIndex() async {
    final f = File(p.join(_wikiDir, 'index.md'));
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  Future<String> readFile(String relativePath) async {
    final f = File(p.join(_wikiDir, relativePath));
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  static List<String> parseLinks(String markdown) {
    final regex = RegExp(r'\[\[([^\]]+)\]\]');
    return regex.allMatches(markdown).map((m) => m.group(1)!).toList();
  }

  Future<WikiGraph> buildGraph() async {
    final wikiDir = Directory(_wikiDir);
    if (!await wikiDir.exists()) {
      return WikiGraph(nodes: [], edges: []);
    }

    final nodes = <WikiNode>[];
    final edges = <WikiEdge>[];
    final files = <String, String>{}; // relative path (no .md) → contents

    await for (final entity in wikiDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.md')) {
        final relative = p.relative(entity.path, from: _wikiDir);
        final relativePath =
            relative.replaceAll('\\', '/').replaceAll('.md', '');
        final contents = await entity.readAsString();
        files[relativePath] = contents;
        nodes.add(WikiNode(
          path: relativePath,
          title: p.basename(relativePath),
        ));
      }
    }

    for (final entry in files.entries) {
      final links = parseLinks(entry.value);
      for (final link in links) {
        if (files.containsKey(link)) {
          edges.add(WikiEdge(from: entry.key, to: link));
        }
      }
    }

    return WikiGraph(nodes: nodes, edges: edges);
  }
}
