import 'package:shared_preferences/shared_preferences.dart';

class AppStorage {
  static const String folderKey = "selected_folder";

  static Future<void> saveFolder(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(folderKey, path);
  }

  static Future<String?> loadFolder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(folderKey);
  }

  static Future<void> clearFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(folderKey);
  }

  static const String firstRunKey = "first_run";

  static Future<bool> isFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(firstRunKey) ?? true;
  }

  static Future<void> setFirstRunFalse() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(firstRunKey, false);
  }

  // Watcher enabled preference
  static const String watcherEnabledKey = "watcher_enabled";

  static Future<void> saveWatcherEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(watcherEnabledKey, enabled);
  }

  static Future<bool> loadWatcherEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(watcherEnabledKey) ?? true;
  }
}
