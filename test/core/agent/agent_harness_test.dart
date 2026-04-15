import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ispy_ios/core/agent/agent_harness.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';

class MockGemmaService extends Mock implements GemmaService {}

void main() {
  late Directory tempDir;
  late MockGemmaService mockGemma;
  late AgentTools tools;
  late AgentHarness harness;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ispy_harness_test_');
    mockGemma = MockGemmaService();
    tools = AgentTools(baseDir: tempDir.path);
    harness = AgentHarness(gemma: mockGemma, tools: tools);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('returns final response when no tool call in output', () async {
    when(() => mockGemma.generate(any()))
        .thenAnswer((_) async => 'I see a window.');

    final result = await harness.run(
      systemPrompt: 'you are ispy.',
      userPrompt: 'what do you see?',
    );

    expect(result, equals('I see a window.'));
  });

  test('executes tool call and feeds result back before final response',
      () async {
    var callCount = 0;
    when(() => mockGemma.generate(any())).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return '<tool_call>{"name": "list_directory", "arguments": {"path": "wiki"}}</tool_call>';
      }
      return 'I looked at my wiki. It is empty.';
    });

    final result = await harness.run(
      systemPrompt: 'you are ispy.',
      userPrompt: 'what do you know?',
    );

    expect(result, contains('wiki'));
    verify(() => mockGemma.generate(any())).called(2);
  });

  test('executes write_file tool and file appears on disk', () async {
    var callCount = 0;
    when(() => mockGemma.generate(any())).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return '<tool_call>{"name": "write_file", "arguments": {"path": "wiki/test.md", "content": "ispy wrote this"}}</tool_call>';
      }
      return 'done.';
    });

    await harness.run(
      systemPrompt: 'you are ispy.',
      userPrompt: 'write something.',
    );

    expect(
      File('${tempDir.path}/wiki/test.md').readAsStringSync(),
      equals('ispy wrote this'),
    );
  });

  test('handles malformed tool call without crashing', () async {
    var callCount = 0;
    when(() => mockGemma.generate(any())).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return '<tool_call>not valid json</tool_call>';
      }
      return 'I recovered.';
    });

    final result = await harness.run(
      systemPrompt: 'you are ispy.',
      userPrompt: 'do something.',
    );

    expect(result, equals('I recovered.'));
  });
}
