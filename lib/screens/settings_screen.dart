import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kPrefsSkipVolumeDialogKey = 'treep_skip_volume_dialog';
const String kPrefsSleepLinesEnabledKey = 'treep_sleep_lines_enabled';
const String kPrefsUpcomingTripsLimitKey = 'treep_upcoming_trips_limit';
const String kPrefsUpcomingWindowHoursKey = 'treep_upcoming_window_hours';
const String kPrefsDarkModeEnabledKey = 'treep_dark_mode_enabled';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _sleepLines = true;
  bool _showTipsDialog = true;
  int _upcomingWindowHours = 2;
  bool _darkModeEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hintPopupEnabled = !(prefs.getBool(kPrefsSkipVolumeDialogKey) ?? false);
      final sleepEnabled = prefs.getBool(kPrefsSleepLinesEnabledKey) ?? true;
      final rawWindowHours = prefs.getInt(kPrefsUpcomingWindowHoursKey) ?? 2;
      final windowHours = <int>{2, 4, 6}.contains(rawWindowHours) ? rawWindowHours : 2;
      final darkEnabled = prefs.getBool(kPrefsDarkModeEnabledKey) ?? false;
      if (!mounted) return;
      setState(() {
        _showTipsDialog = hintPopupEnabled;
        _sleepLines = sleepEnabled;
        _upcomingWindowHours = windowHours;
        _darkModeEnabled = darkEnabled;
      });
    } catch (_) {}
  }

  Future<void> _setSleepLines(bool v) async {
    setState(() => _sleepLines = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefsSleepLinesEnabledKey, v);
  }

  Future<void> _setShowTips(bool v) async {
    setState(() => _showTipsDialog = v);
    final prefs = await SharedPreferences.getInstance();
    // We store the inverse as "skip" for backwards-compat.
    await prefs.setBool(kPrefsSkipVolumeDialogKey, !v);
  }

  Future<void> _setUpcomingWindowHours(int v) async {
    if (!<int>{2, 4, 6}.contains(v)) return;
    setState(() => _upcomingWindowHours = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrefsUpcomingWindowHoursKey, v);
  }

  Future<void> _setDarkModeEnabled(bool v) async {
    setState(() => _darkModeEnabled = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefsDarkModeEnabledKey, v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Sprüche aktivieren'),
            subtitle: const Text('Treep zeigt nach dem Alarm setzen zufällige Sprüche.'),
            value: _sleepLines,
            onChanged: (v) => _setSleepLines(v),
          ),
          SwitchListTile(
            title: const Text('Hinweis-Popup anzeigen'),
            subtitle: const Text('Kurzer Check (Lautstärke / Fokus / Bluetooth) vor dem Schlafen.'),
            value: _showTipsDialog,
            onChanged: (v) => _setShowTips(v),
          ),
          ListTile(
            title: const Text('Upcoming connections window'),
            subtitle: const Text('Wie weit in die Zukunft Verbindungen gesucht werden.'),
            trailing: DropdownButton<int>(
              value: _upcomingWindowHours,
              onChanged: (v) {
                if (v == null) return;
                _setUpcomingWindowHours(v);
              },
              items: const [
                DropdownMenuItem(value: 2, child: Text('2 hours')),
                DropdownMenuItem(value: 4, child: Text('4 hours')),
                DropdownMenuItem(value: 6, child: Text('6 hours')),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Dark mode'),
            subtitle: const Text('Use dark appearance'),
            secondary: const Icon(Icons.dark_mode_outlined),
            value: _darkModeEnabled,
            onChanged: (v) => _setDarkModeEnabled(v),
          ),
          const Divider(height: 1),
          ListTile(
            title: const Text('Sprüche-Sammlung (bald)'),
            subtitle: const Text('Später: gesammelt / selten / trophies.'),
            trailing: const Icon(Icons.lock_outline),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon.')),
              );
            },
          ),
          ListTile(
            title: const Text('Stats (bald)'),
            subtitle: const Text('Später: Reaktionszeit, längster Sleep, usw.'),
            trailing: const Icon(Icons.lock_outline),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon.')),
              );
            },
          ),
        ],
      ),
    );
  }
}
