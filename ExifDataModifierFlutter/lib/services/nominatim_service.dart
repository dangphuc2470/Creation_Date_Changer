import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for reverse geocoding using OSM Nominatim.
///
/// Rate limit: max 1 request/second per Nominatim policy.
/// Results are cached in-memory and persisted to SharedPreferences for custom names.
class NominatimService {
  NominatimService._();
  static final NominatimService instance = NominatimService._();

  // In-memory cache: "lat,lng" → display label
  final Map<String, String> _cache = {};
  // Tracks in-flight requests to avoid duplicate calls
  final Map<String, Future<String?>> _inflight = {};

  DateTime _lastRequestTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minInterval = Duration(milliseconds: 1100); // ~1 req/s

  static const String _prefsKey = 'nominatim_custom_place_names';
  bool _isLoaded = false;

  /// Loads persisted custom place names from SharedPreferences.
  Future<void> _ensureLoaded() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_prefsKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>?;
        if (map != null) {
          map.forEach((k, v) {
            if (v is String) _cache[k] = v;
          });
        }
      }
    } catch (_) {}
    _isLoaded = true;
  }

  /// Sets and persists a custom place name for coordinates.
  Future<void> setCustomName(double lat, double lng, String customName) async {
    final key = _roundKey(lat, lng);
    final key4 = _roundKey4(lat, lng);
    _cache[key] = customName;
    _cache[key4] = customName;

    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_prefsKey);
      Map<String, dynamic> map = {};
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>?;
        if (decoded != null) map = decoded;
      }
      map[key] = customName;
      map[key4] = customName;
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (_) {}
  }

  /// Returns a short human-readable place name for the given coordinates.
  /// Checks persistent custom cache first before calling API.
  Future<String?> reverseLookup(double lat, double lng) async {
    await _ensureLoaded();

    final key4 = _roundKey4(lat, lng);
    if (_cache.containsKey(key4)) return _cache[key4];

    final key = _roundKey(lat, lng);
    if (_cache.containsKey(key)) return _cache[key];

    // Deduplicate concurrent requests for same key
    if (_inflight.containsKey(key)) return _inflight[key];

    final future = _doLookup(lat, lng, key);
    _inflight[key] = future;
    final result = await future;
    _inflight.remove(key);
    return result;
  }


  Future<String?> _doLookup(double lat, double lng, String key) async {
    // Enforce rate limit
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestTime);
    if (elapsed < _minInterval) {
      await Future.delayed(_minInterval - elapsed);
    }
    _lastRequestTime = DateTime.now();

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&zoom=17&addressdetails=1',
      );
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ExifDataModifierApp/1.0');
      request.headers.set('Accept', 'application/json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode != 200) return null;

      final json = jsonDecode(body) as Map<String, dynamic>?;
      if (json == null) return null;

      final label = _extractLabel(json);
      if (label != null) _cache[key] = label;
      return label;
    } catch (_) {
      return null;
    }
  }

  /// Build a short, useful display label from Nominatim JSON response.
  String? _extractLabel(Map<String, dynamic> json) {
    final address = json['address'] as Map<String, dynamic>?;
    if (address == null) return null;

    // Priority: named POI → amenity → road+suburb
    final name = json['name'] as String?;
    final amenity = address['amenity'] as String?;
    final shop = address['shop'] as String?;
    final tourism = address['tourism'] as String?;
    final leisure = address['leisure'] as String?;
    final building = address['building'] as String?;

    final poi = name?.isNotEmpty == true
        ? name
        : amenity?.isNotEmpty == true
            ? amenity
            : shop?.isNotEmpty == true
                ? shop
                : tourism?.isNotEmpty == true
                    ? tourism
                    : leisure?.isNotEmpty == true
                        ? leisure
                        : building?.isNotEmpty == true
                            ? building
                            : null;

    if (poi != null && poi.isNotEmpty) return poi;

    // Fallback: road + suburb or quarter
    final road = address['road'] as String? ??
        address['pedestrian'] as String? ??
        address['footway'] as String?;
    final suburb = address['suburb'] as String? ??
        address['quarter'] as String? ??
        address['neighbourhood'] as String?;

    if (road != null && suburb != null) return '$road, $suburb';
    if (road != null) return road;
    if (suburb != null) return suburb;

    final city = address['city'] as String? ??
        address['town'] as String? ??
        address['village'] as String?;
    return city;
  }

  /// Round lat/lng to ~50m precision for cache keying.
  String _roundKey(double lat, double lng) {
    final la = (lat * 1000).round() / 1000;
    final lo = (lng * 1000).round() / 1000;
    return '$la,$lo';
  }

  /// Round lat/lng to 4 decimals (~11m) precision.
  String _roundKey4(double lat, double lng) {
    return '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
  }

  /// Forward-geocode search near a bias point.
  /// Returns up to [limit] results sorted by relevance.
  Future<List<NominatimResult>> search(
    String query, {
    double? lat,
    double? lng,
    int limit = 8,
  }) async {
    if (query.trim().isEmpty) return [];

    // Enforce rate limit
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestTime);
    if (elapsed < _minInterval) {
      await Future.delayed(_minInterval - elapsed);
    }
    _lastRequestTime = DateTime.now();

    try {
      String url = 'https://nominatim.openstreetmap.org/search'
          '?q=${Uri.encodeQueryComponent(query)}'
          '&format=json&addressdetails=1&limit=$limit';
      if (lat != null && lng != null) {
        // Bias results toward this location
        url +=
            '&viewbox=${lng - 0.5},${lat + 0.5},${lng + 0.5},${lat - 0.5}&bounded=0';
      }

      final uri = Uri.parse(url);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'ExifDataModifierApp/1.0');
      request.headers.set('Accept', 'application/json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode != 200) return [];

      final list = jsonDecode(body) as List<dynamic>?;
      if (list == null) return [];

      return list
          .whereType<Map<String, dynamic>>()
          .map(NominatimResult.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  void clearCache() => _cache.clear();
}

/// A single result returned by Nominatim search.
class NominatimResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;

  NominatimResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
  });

  factory NominatimResult.fromJson(Map<String, dynamic> json) {
    final address = json['address'] as Map<String, dynamic>? ?? {};
    final name = (json['name'] as String?)?.trim() ?? '';
    final road = (address['road'] as String?)?.trim() ??
        (address['pedestrian'] as String?)?.trim() ??
        '';
    final suburb = (address['suburb'] as String?)?.trim() ??
        (address['quarter'] as String?)?.trim() ??
        (address['neighbourhood'] as String?)?.trim() ??
        '';
    final city = (address['city'] as String?)?.trim() ??
        (address['town'] as String?)?.trim() ??
        (address['village'] as String?)?.trim() ??
        '';

    // Build a concise short name
    String short = name.isNotEmpty ? name : (road.isNotEmpty ? road : suburb);
    if (short.isEmpty) short = city;
    if (city.isNotEmpty && short != city) short += ', $city';

    return NominatimResult(
      displayName: json['display_name'] as String? ?? short,
      shortName: short,
      lat: double.tryParse(json['lat'] as String? ?? '') ?? 0,
      lng: double.tryParse(json['lon'] as String? ?? '') ?? 0,
    );
  }
}
