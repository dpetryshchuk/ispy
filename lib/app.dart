import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/features/setup/model_download_screen.dart';
import 'package:ispy_ios/shared/ispy_tab_bar.dart';

class IspyApp extends StatefulWidget {
  const IspyApp({super.key});

  @override
  State<IspyApp> createState() => _IspyAppState();
}

class _IspyAppState extends State<IspyApp> {
  final GemmaService _gemmaService = GemmaService();
  bool _loading = true;
  bool _needsDownload = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      await FlutterGemma.initialize();
      final exists = await _gemmaService.modelExists();
      if (!exists) {
        if (mounted) setState(() { _loading = false; _needsDownload = true; });
        return;
      }
      await _gemmaService.load();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onModelDownloaded() {
    setState(() { _needsDownload = false; _loading = true; });
    _loadModel();
  }

  @override
  void dispose() {
    _gemmaService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ispy',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF080808),
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 0.5),
          ),
        ),
      ),
      home: _loading
          ? const _SplashScreen()
          : _needsDownload
              ? ModelDownloadScreen(onModelReady: _onModelDownloaded)
              : _error != null
                  ? _ModelErrorScreen(message: _error!)
                  : IspyTabBar(gemmaService: _gemmaService),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ispy',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                letterSpacing: 8,
                fontWeight: FontWeight.w100,
              ),
            ),
            SizedBox(height: 32),
            Text(
              'waking up.',
              style: TextStyle(
                color: Color(0x2EFFFFFF),
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelErrorScreen extends StatelessWidget {
  final String message;
  const _ModelErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Text(
            message,
            style: const TextStyle(
              color: Colors.white30,
              fontSize: 12,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
