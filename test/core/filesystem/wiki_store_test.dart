import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ispy_ios/core/filesystem/wiki_store.dart';

void main() {
  late Directory tempDir;
  late WikiStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ispy_wiki_test_');
    store = WikiStore(baseDir: tempDir.path);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('readIndex returns empty string when index does not exist', () async {
    final result = await store.readIndex();
    expect(result, equals(''));
  });

  test('readFile returns file contents', () async {
    final wikiDir = Directory('${tempDir.path}/wiki/places');
    await wikiDir.create(recursive: true);
    await File('${tempDir.path}/wiki/places/home.md').writeAsString('my home');
    final result = await store.readFile('places/home.md');
    expect(result, equals('my home'));
  });

  test('readFile returns empty string when file missing', () async {
    final result = await store.readFile('places/missing.md');
    expect(result, equals(''));
  });

  test('parseLinks extracts [[wikilinks]] from markdown', () async {
    const markdown =
        'I saw a window. See also [[places/home]] and [[plants/palm_trees]].';
    final links = WikiStore.parseLinks(markdown);
    expect(links, containsAll(['places/home', 'plants/palm_trees']));
  });

  test('parseLinks returns empty list when no links present', () {
    final links = WikiStore.parseLinks('no links here');
    expect(links, isEmpty);
  });

  test('buildGraph returns empty graph when wiki dir missing', () async {
    final graph = await store.buildGraph();
    expect(graph.nodes, isEmpty);
    expect(graph.edges, isEmpty);
  });

  test('buildGraph returns nodes and edges from wiki files', () async {
    final wikiDir = Directory('${tempDir.path}/wiki');
    await wikiDir.create(recursive: true);
    await File('${tempDir.path}/wiki/index.md')
        .writeAsString('see [[places/home]]');
    await Directory('${tempDir.path}/wiki/places').create(recursive: true);
    await File('${tempDir.path}/wiki/places/home.md')
        .writeAsString('has [[plants/palm_trees]]');
    await Directory('${tempDir.path}/wiki/plants').create(recursive: true);
    await File('${tempDir.path}/wiki/plants/palm_trees.md')
        .writeAsString('tall trees');

    final graph = await store.buildGraph();
    expect(graph.nodes.length, equals(3));
    expect(
        graph.edges.any((e) => e.from == 'index' && e.to == 'places/home'),
        isTrue);
    expect(
        graph.edges
            .any((e) => e.from == 'places/home' && e.to == 'plants/palm_trees'),
        isTrue);
  });
}
