//بسم الله الرحمن الرحيم

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/alarm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await NotificationService.init();
  runApp(const TreepApp());
}

class TreepApp extends StatefulWidget {
  const TreepApp({super.key});

  @override
  State<TreepApp> createState() => _TreepAppState();
}

class _TreepAppState extends State<TreepApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _reloadAppearanceMode();
  }

  Future<void> _reloadAppearanceMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final darkEnabled = prefs.getBool(kPrefsDarkModeEnabledKey) ?? false;
      final mode = darkEnabled ? ThemeMode.dark : ThemeMode.light;
      if (!mounted) return;
      setState(() => _themeMode = mode);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Treep',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B5E20),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: TreepHome(onPreferencesChanged: _reloadAppearanceMode),
    );
  }
}
