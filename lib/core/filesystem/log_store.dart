import 'dart:io';
import 'package:path/path.dart' as p;

class LogEntry {
  final String path;
  final DateTime timestamp;
  final String entryMarkdown;

  LogEntry({
    required this.path,
    required this.timestamp,
    required this.entryMarkdown,
  });
}

class LogStore {
  final String baseDir;

  LogStore({required this.baseDir});

  String get _logDir => p.join(baseDir, 'log');

  String _timestampToFolderName(DateTime utc) {
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}-'
        '${utc.minute.toString().padLeft(2, '0')}-'
        '${utc.second.toString().padLeft(2, '0')}Z';
  }

  DateTime _folderNameToTimestamp(String name) {
    // format: 2026-04-14T14-23-00Z
    final clean = name.replaceAll('Z', '').split('T');
    final dateParts = clean[0].split('-');
    final timeParts = clean[1].split('-');
    return DateTime.utc(
      int.parse(dateParts[0]),
      int.parse(dateParts[1]),
      int.parse(dateParts[2]),
      int.parse(timeParts[0]),
      int.parse(timeParts[1]),
      int.parse(timeParts[2]),
    );
  }

  /// Creates the log folder and saves the photo.
  /// Does NOT write entry.md — ispy writes that itself via the write_file tool.
  Future<String> createFolder({
    required DateTime timestamp,
    required List<int> photoBytes,
  }) async {
    final folderName = _timestampToFolderName(timestamp.toUtc());
    final entryPath = p.join(_logDir, folderName);
    await Directory(entryPath).create(recursive: true);
    if (photoBytes.isNotEmpty) {
      await File(p.join(entryPath, 'photo.jpg')).writeAsBytes(photoBytes);
    }
    return entryPath;
  }

  Future<List<LogEntry>> listEntries() async {
    final logDir = Directory(_logDir);
    if (!await logDir.exists()) return [];

    final folders = await logDir
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();

    folders.sort((a, b) => b.path.compareTo(a.path)); // newest first

    final entries = <LogEntry>[];
    for (final folder in folders) {
      final entryFile = File(p.join(folder.path, 'entry.md'));
      if (await entryFile.exists()) {
        entries.add(LogEntry(
          path: folder.path,
          timestamp: _folderNameToTimestamp(p.basename(folder.path)),
          entryMarkdown: await entryFile.readAsString(),
        ));
      }
    }
    return entries;
  }
}
