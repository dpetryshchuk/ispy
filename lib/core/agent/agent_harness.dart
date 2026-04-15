import 'dart:convert';
import 'package:ispy_ios/core/agent/tool_definitions.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';

class AgentHarness {
  final GemmaService gemma;
  final AgentTools tools;
  static const int _maxIterations = 12;

  AgentHarness({required this.gemma, required this.tools});

  Future<String> run({
    required String systemPrompt,
    required String userPrompt,
    int maxIterations = _maxIterations,
  }) async {
    final toolsDescription = _buildToolsDescription();
    var conversation = '$systemPrompt\n\n'
        'you have access to these tools:\n$toolsDescription\n\n'
        'to call a tool, output exactly:\n'
        '<tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>\n\n'
        'you may call multiple tools in sequence. when you are done, '
        'write your final response without any tool_call tags.\n\n'
        '$userPrompt';

    for (int i = 0; i < maxIterations; i++) {
      final response = await gemma.generate(conversation);

      final toolCallMatch =
          RegExp(r'<tool_call>(.*?)</tool_call>', dotAll: true)
              .firstMatch(response);

      if (toolCallMatch == null) {
        // No tool call — this is the final response
        return response;
      }

      // Execute the tool
      final toolCallJson = toolCallMatch.group(1)!.trim();
      String toolResult;
      try {
        final parsed = jsonDecode(toolCallJson) as Map<String, dynamic>;
        final name = parsed['name'] as String;
        final arguments =
            (parsed['arguments'] as Map<String, dynamic>?) ?? {};
        toolResult = await tools.execute(name, arguments);
      } catch (e) {
        toolResult = 'error: could not parse tool call — $e';
      }

      conversation += '\n\nassistant: $response\n'
          'tool_result: $toolResult';
    }

    return 'ispy reached the end of its thinking.';
  }

  String _buildToolsDescription() {
    return kIspyToolDefinitions.map((tool) {
      final params =
          (tool['parameters'] as Map)['properties'] as Map<String, dynamic>;
      final paramList = params.keys.join(', ');
      return '${tool['name']}($paramList): ${tool['description']}';
    }).join('\n');
  }
}
