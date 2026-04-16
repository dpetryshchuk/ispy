import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ispy_ios/core/filesystem/wiki_store.dart';
import 'package:ispy_ios/features/wiki/wiki_detail_screen.dart';

class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key});

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  WikiGraph? _wikiGraph;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = WikiStore(baseDir: docsDir.path);
    final graph = await store.buildGraph();
    if (mounted) {
      setState(() {
        _wikiGraph = graph;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white12)),
      );
    }

    if (_wikiGraph == null || _wikiGraph!.nodes.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'ispy has not built its wiki yet.',
            style: TextStyle(color: Colors.white24, fontSize: 13),
          ),
        ),
      );
    }

    final graph = Graph();
    final nodeMap = <String, Node>{};

    for (final wikiNode in _wikiGraph!.nodes) {
      final node = Node.Id(wikiNode.path);
      nodeMap[wikiNode.path] = node;
      graph.addNode(node);
    }

    for (final edge in _wikiGraph!.edges) {
      final from = nodeMap[edge.from];
      final to = nodeMap[edge.to];
      if (from != null && to != null) {
        graph.addEdge(
          from,
          to,
          paint: Paint()
            ..color = Colors.white.withOpacity(0.08)
            ..strokeWidth = 1,
        );
      }
    }

    final algorithm = FruchtermanReingoldAlgorithm(FruchtermanReingoldConfiguration(iterations: 1000));

    return Scaffold(
      backgroundColor: Colors.black,
      body: InteractiveViewer(
        constrained: false,
        boundaryMargin: const EdgeInsets.all(300),
        minScale: 0.2,
        maxScale: 4.0,
        child: GraphView(
          graph: graph,
          algorithm: algorithm,
          paint: Paint()
            ..color = Colors.white.withOpacity(0.06)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
          builder: (node) {
            final path = node.key!.value as String;
            final wikiNode =
                _wikiGraph!.nodes.firstWhere((n) => n.path == path);
            final connectionCount = _wikiGraph!.edges
                .where((e) => e.from == path || e.to == path)
                .length;
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => WikiDetailScreen(wikiNodePath: path),
                ),
              ),
              child: _WikiNodeWidget(
                title: wikiNode.title,
                connectionCount: connectionCount,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WikiNodeWidget extends StatelessWidget {
  final String title;
  final int connectionCount;

  const _WikiNodeWidget({
    required this.title,
    required this.connectionCount,
  });

  @override
  Widget build(BuildContext context) {
    final size = (30.0 + connectionCount * 6.0).clamp(30.0, 72.0);
    final opacity = (0.08 + connectionCount * 0.04).clamp(0.08, 0.4);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withOpacity(opacity),
        border: Border.all(
          color: Colors.white.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            title,
            style: const TextStyle(color: Colors.white54, fontSize: 7),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ),
    );
  }
}
