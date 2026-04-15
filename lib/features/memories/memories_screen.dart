import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ispy_ios/core/filesystem/log_store.dart';
import 'package:intl/intl.dart';

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  List<LogEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = LogStore(baseDir: docsDir.path);
    final entries = await store.listEntries();
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white12),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: _entries.isEmpty
          ? const Center(
              child: Text(
                'ispy has not seen anything yet.',
                style: TextStyle(color: Colors.white24, fontSize: 13),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(top: 56, bottom: 24),
              itemCount: _entries.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.white12, indent: 72),
              itemBuilder: (context, index) =>
                  _EntryTile(entry: _entries[index]),
            ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final LogEntry entry;
  const _EntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final photoFile = File(p.join(entry.path, 'photo.jpg'));
    final firstLine = entry.entryMarkdown
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final timeLabel =
        DateFormat('MMM d · h:mm a').format(entry.timestamp.toLocal());

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: photoFile.existsSync()
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                photoFile,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
            )
          : Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white08,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
      title: Text(
        firstLine,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          timeLabel,
          style: const TextStyle(color: Colors.white24, fontSize: 11),
        ),
      ),
      onTap: () => _showDetail(context),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0D0D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.95,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                entry.entryMarkdown,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
