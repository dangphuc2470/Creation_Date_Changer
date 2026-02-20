import 'package:shared_preferences/shared_preferences.dart';

enum MapType {
  openStreetMap,
  googleNormal,
  googleSatellite,
}

/// Service to manage map provider preferences
class MapService {
  static const String _mapTypeKey = 'selected_map_type';
  
  /// Get saved map type preference
  static Future<MapType> getMapType() async {
    final prefs = await SharedPreferences.getInstance();
    final typeIndex = prefs.getInt(_mapTypeKey) ?? 0;
    return MapType.values[typeIndex];
  }
  
  /// Save map type preference
  static Future<void> setMapType(MapType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_mapTypeKey, type.index);
  }
  
  /// Get display name for map type
  static String getMapTypeName(MapType type) {
    switch (type) {
      case MapType.openStreetMap:
        return 'OpenStreetMap';
      case MapType.googleNormal:
        return 'Google Maps';
      case MapType.googleSatellite:
        return 'Satellite';
    }
  }
}
