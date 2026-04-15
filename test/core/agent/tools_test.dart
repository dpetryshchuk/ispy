import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ispy_ios/core/agent/tools.dart';

void main() {
  late Directory tempDir;
  late AgentTools tools;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ispy_tools_test_');
    tools = AgentTools(baseDir: tempDir.path);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('write_file creates file with content', () async {
    final result = await tools.execute('write_file', {
      'path': 'wiki/index.md',
      'content': '# index\nsee [[places/home]]',
    });
    expect(result, equals('ok'));
    expect(
      File('${tempDir.path}/wiki/index.md').readAsStringSync(),
      equals('# index\nsee [[places/home]]'),
    );
  });

  test('read_file returns file contents', () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    await File('${tempDir.path}/wiki/index.md').writeAsString('hello');
    final result = await tools.execute('read_file', {'path': 'wiki/index.md'});
    expect(result, equals('hello'));
  });

  test('read_file returns error message when file missing', () async {
    final result =
        await tools.execute('read_file', {'path': 'wiki/missing.md'});
    expect(result, contains('not found'));
  });

  test('list_directory returns file names', () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    await File('${tempDir.path}/wiki/index.md').writeAsString('');
    await File('${tempDir.path}/wiki/patterns.md').writeAsString('');
    final result =
        await tools.execute('list_directory', {'path': 'wiki'});
    expect(result, contains('index.md'));
    expect(result, contains('patterns.md'));
  });

  test('list_directory returns (empty) for empty dir', () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    final result =
        await tools.execute('list_directory', {'path': 'wiki'});
    expect(result, equals('(empty)'));
  });

  test('search_files finds matching content', () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    await File('${tempDir.path}/wiki/home.md').writeAsString('arched window');
    await File('${tempDir.path}/wiki/other.md').writeAsString('no match here');
    final result =
        await tools.execute('search_files', {'query': 'arched window'});
    expect(result, contains('home.md'));
    expect(result, isNot(contains('other.md')));
  });

  test('search_files returns no results message when nothing matches',
      () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    await File('${tempDir.path}/wiki/home.md').writeAsString('something else');
    final result =
        await tools.execute('search_files', {'query': 'palm trees'});
    expect(result, contains('no results'));
  });

  test('path traversal outside baseDir is blocked', () async {
    final result =
        await tools.execute('read_file', {'path': '../../etc/passwd'});
    expect(result, contains('access denied'));
  });

  test('move_file renames file', () async {
    await Directory('${tempDir.path}/wiki').create(recursive: true);
    await File('${tempDir.path}/wiki/old.md').writeAsString('content');
    final result = await tools.execute('move_file', {
      'from': 'wiki/old.md',
      'to': 'wiki/new.md',
    });
    expect(result, equals('ok'));
    expect(File('${tempDir.path}/wiki/new.md').existsSync(), isTrue);
    expect(File('${tempDir.path}/wiki/old.md').existsSync(), isFalse);
  });
}
