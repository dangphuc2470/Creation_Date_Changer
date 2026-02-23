import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _timezoneOffsetKey = 'timezone_offset';

  /// Get saved timezone offset in hours
  static Future<double> getTimezoneOffset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_timezoneOffsetKey) ?? 0.0;
  }

  /// Save timezone offset in hours
  static Future<void> setTimezoneOffset(double offset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_timezoneOffsetKey, offset);
  }
}
