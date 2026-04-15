import 'package:flutter/material.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/features/capture/capture_screen.dart';
import 'package:ispy_ios/features/chat/chat_screen.dart';
import 'package:ispy_ios/features/memories/memories_screen.dart';
import 'package:ispy_ios/features/wiki/wiki_screen.dart';

class IspyTabBar extends StatefulWidget {
  final GemmaService gemmaService;
  const IspyTabBar({super.key, required this.gemmaService});

  @override
  State<IspyTabBar> createState() => _IspyTabBarState();
}

class _IspyTabBarState extends State<IspyTabBar> {
  int _index = 0;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      CaptureScreen(gemmaService: widget.gemmaService),
      const MemoriesScreen(),
      const WikiScreen(),
      ChatScreen(gemmaService: widget.gemmaService),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF080808),
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        indicatorColor: Colors.white10,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radio_button_off, color: Colors.white24, size: 20),
            selectedIcon:
                Icon(Icons.radio_button_on, color: Colors.white54, size: 20),
            label: 'capture',
          ),
          NavigationDestination(
            icon: Icon(Icons.access_time, color: Colors.white24, size: 20),
            selectedIcon:
                Icon(Icons.access_time_filled, color: Colors.white54, size: 20),
            label: 'memories',
          ),
          NavigationDestination(
            icon: Icon(Icons.blur_on, color: Colors.white24, size: 20),
            selectedIcon:
                Icon(Icons.blur_circular, color: Colors.white54, size: 20),
            label: 'wiki',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline,
                color: Colors.white24, size: 20),
            selectedIcon:
                Icon(Icons.chat_bubble, color: Colors.white54, size: 20),
            label: 'chat',
          ),
        ],
      ),
    );
  }
}
