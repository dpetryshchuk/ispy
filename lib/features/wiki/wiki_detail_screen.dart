import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ispy_ios/core/filesystem/wiki_store.dart';

class WikiDetailScreen extends StatefulWidget {
  final String wikiNodePath;
  const WikiDetailScreen({super.key, required this.wikiNodePath});

  @override
  State<WikiDetailScreen> createState() => _WikiDetailScreenState();
}

class _WikiDetailScreenState extends State<WikiDetailScreen> {
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = WikiStore(baseDir: docsDir.path);
    final content = await store.readFile('${widget.wikiNodePath}.md');
    if (mounted) {
      setState(() {
        _content = content;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white24, size: 16),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.wikiNodePath,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 12,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white12))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
              child: Text(
                _content.isEmpty ? 'this page is empty.' : _content,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  height: 1.8,
                ),
              ),
            ),
    );
  }
}
