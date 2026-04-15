import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ispy_ios/core/filesystem/log_store.dart';

void main() {
  late Directory tempDir;
  late LogStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ispy_test_');
    store = LogStore(baseDir: tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('creates entry folder named by UTC timestamp', () async {
    final timestamp = DateTime.utc(2026, 4, 14, 14, 23, 0);
    final path = await store.createFolder(
      timestamp: timestamp,
      photoBytes: [1, 2, 3],
    );
    expect(Directory(path).existsSync(), isTrue);
    expect(path, contains('2026-04-14T14-23-00Z'));
  });

  test('writes photo.jpg inside entry folder', () async {
    final timestamp = DateTime.utc(2026, 4, 14, 14, 23, 0);
    final path = await store.createFolder(
      timestamp: timestamp,
      photoBytes: [1, 2, 3],
    );
    expect(File('$path/photo.jpg').existsSync(), isTrue);
    expect(File('$path/entry.md').existsSync(), isFalse);
  });

  test('listEntries returns entries sorted newest first', () async {
    final path1 = await store.createFolder(
      timestamp: DateTime.utc(2026, 4, 14, 10, 0, 0),
      photoBytes: [],
    );
    await File('$path1/entry.md').writeAsString('first');

    final path2 = await store.createFolder(
      timestamp: DateTime.utc(2026, 4, 14, 14, 0, 0),
      photoBytes: [],
    );
    await File('$path2/entry.md').writeAsString('second');

    final entries = await store.listEntries();
    expect(entries.first.entryMarkdown, equals('second'));
    expect(entries.last.entryMarkdown, equals('first'));
  });

  test('listEntries skips folders with no entry.md', () async {
    await store.createFolder(
      timestamp: DateTime.utc(2026, 4, 14, 10, 0, 0),
      photoBytes: [],
    );
    final entries = await store.listEntries();
    expect(entries, isEmpty);
  });
}
