import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ispy_ios/core/agent/agent_harness.dart';
import 'package:ispy_ios/core/agent/prompts.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/filesystem/wiki_store.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';

class _Message {
  final String text;
  final bool isUser;
  _Message({required this.text, required this.isUser});
}

class ChatScreen extends StatefulWidget {
  final GemmaService gemmaService;
  const ChatScreen({super.key, required this.gemmaService});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Message> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _thinking = false;

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _thinking) return;

    setState(() {
      _messages.add(_Message(text: text, isUser: true));
      _thinking = true;
    });
    _input.clear();
    _scrollToBottom();

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final wikiStore = WikiStore(baseDir: docsDir.path);
      final tools = AgentTools(baseDir: docsDir.path);
      final harness = AgentHarness(gemma: widget.gemmaService, tools: tools);
      final wikiIndex = await wikiStore.readIndex();

      final response = await harness.run(
        systemPrompt: Prompts.ispySystemPrompt,
        userPrompt: Prompts.chatPrompt(
          wikiIndex: wikiIndex,
          userMessage: text,
        ),
      );

      if (mounted) {
        setState(() {
          _messages.add(_Message(text: response, isUser: false));
          _thinking = false;
        });
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _messages.add(_Message(
            text: 'ispy could not respond.',
            isUser: false,
          ));
          _thinking = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'ispy is listening.',
                      style:
                          TextStyle(color: Colors.white12, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 56, 20, 8),
                    itemCount: _messages.length + (_thinking ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_thinking && index == _messages.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            '...',
                            style: TextStyle(
                                color: Colors.white24, fontSize: 13),
                          ),
                        );
                      }
                      final msg = _messages[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          msg.text,
                          style: TextStyle(
                            color: msg.isUser
                                ? Colors.white38
                                : Colors.white70,
                            fontSize: 14,
                            height: 1.6,
                          ),
                          textAlign: msg.isUser
                              ? TextAlign.right
                              : TextAlign.left,
                        ),
                      );
                    },
                  ),
          ),
          Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0x14FFFFFF)),
              ),
            ),
            padding: EdgeInsets.only(
              left: 20,
              right: 8,
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'ask ispy something',
                      hintStyle: TextStyle(color: Color(0x2EFFFFFF)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                    textInputAction: TextInputAction.send,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.arrow_upward,
                    color: Colors.white24,
                    size: 18,
                  ),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
