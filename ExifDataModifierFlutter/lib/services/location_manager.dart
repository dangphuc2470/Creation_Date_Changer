import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../models/location_point.dart';
import '../utils/geo_utils.dart';

class DateInfo {
  final DateTime date;
  final int pointCount;
  final String filePath;
  final double distance;
  final String state; // "original", "edited", "snapped"
  final String source; // "merge", "timeline", "gpx"
  final bool hasTimelineBackup;
  final bool hasGpxBackup;
  
  DateInfo({
    required this.date,
    required this.pointCount,
    required this.filePath,
    required this.distance,
    required this.state,
    required this.source,
    required this.hasTimelineBackup,
    required this.hasGpxBackup,
  });
}

/// Service to manage exported location data
class LocationManager {
  static final Map<String, List<LocationPoint>> _pointsCache = {};

  /// Scan exported folder and get list of available dates
  static Future<List<DateInfo>> scanExportedData(String rootPath) async {
    _pointsCache.clear();
    final List<DateInfo> dates = [];
    final rootDir = Directory(rootPath);

    if (!await rootDir.exists()) {
      return dates;
    }

    final originalDir = Directory(rootPath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    ));

    // Load metadata cache from disk
    final cacheFile = File(path.join(rootDir.parent.path, 'active_metadata_cache.json'));
    Map<String, Map<String, dynamic>> cache = {};
    if (await cacheFile.exists()) {
      try {
        final jsonStr = await cacheFile.readAsString();
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          cache = decoded.map((k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)));
        }
      } catch (e) {
        debugPrint('Error loading metadata cache: $e');
      }
    }

    bool cacheUpdated = false;

    await for (final entity in rootDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final fileName = path.basename(entity.path);
        if (fileName.contains('_timeline') || fileName.contains('_gpx')) {
          continue; // skip original segments if placed here
        }

        final dateStr = fileName.replaceAll('.json', '');
        final parts = dateStr.split('-');
        if (parts.length != 3) continue;
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year == null || month == null || day == null) continue;

        try {
          final stat = await entity.stat();
          final lastMod = stat.modified.millisecondsSinceEpoch;

          // Check for backups in original folder
          bool hasTimeline = false;
          bool hasGpx = false;
          if (await originalDir.exists()) {
            hasTimeline = await File(path.join(originalDir.path, '${dateStr}_timeline.json')).exists();
            hasGpx = await File(path.join(originalDir.path, '${dateStr}_gpx.json')).exists();
          }

          if (cache.containsKey(entity.path) &&
              cache[entity.path]!['lastModifiedMs'] == lastMod &&
              cache[entity.path]!['hasTimelineBackup'] == hasTimeline &&
              cache[entity.path]!['hasGpxBackup'] == hasGpx) {
            // Use cached values
            final c = cache[entity.path]!;
            dates.add(DateInfo(
              date: DateTime(year, month, day),
              pointCount: c['pointCount'] as int,
              filePath: entity.path,
              distance: (c['distance'] as num).toDouble(),
              state: c['state'] as String,
              source: c['source'] as String,
              hasTimelineBackup: hasTimeline,
              hasGpxBackup: hasGpx,
            ));
          } else {
            // Load and parse
            final jsonString = await entity.readAsString();
            final decoded = jsonDecode(jsonString);
            final points = LocationPoint.parseAnyJson(decoded);
            _pointsCache[entity.path] = points;

            final distance = GeoUtils.calculateTrackDistance(points);

            String state = 'original';
            String source = 'merge';
            if (decoded is Map<String, dynamic>) {
              final properties = decoded['properties'] as Map<String, dynamic>? ?? {};
              state = properties['state'] as String? ?? 'original';
              source = properties['source'] as String? ?? 'merge';
            }

            dates.add(DateInfo(
              date: DateTime(year, month, day),
              pointCount: points.length,
              filePath: entity.path,
              distance: distance,
              state: state,
              source: source,
              hasTimelineBackup: hasTimeline,
              hasGpxBackup: hasGpx,
            ));

            cache[entity.path] = {
              'pointCount': points.length,
              'distance': distance,
              'state': state,
              'source': source,
              'lastModifiedMs': lastMod,
              'hasTimelineBackup': hasTimeline,
              'hasGpxBackup': hasGpx,
            };
            cacheUpdated = true;
          }
        } catch (e) {
          if (kDebugMode) {
            print('Error scanning file ${entity.path}: $e');
          }
        }
      }
    }

    // Clean up cache for deleted files
    final activePaths = dates.map((d) => d.filePath).toSet();
    final cacheKeys = cache.keys.toList();
    for (final key in cacheKeys) {
      if (!activePaths.contains(key)) {
        cache.remove(key);
        cacheUpdated = true;
      }
    }

    if (cacheUpdated) {
      try {
        await cacheFile.writeAsString(jsonEncode(cache), flush: true);
      } catch (e) {
        debugPrint('Error saving metadata cache: $e');
      }
    }

    // Sort by date descending
    dates.sort((a, b) => b.date.compareTo(a.date));

    return dates;
  }
  
  /// Load location points from a file
  static Future<List<LocationPoint>> loadLocationFile(String filePath) async {
    if (_pointsCache.containsKey(filePath)) {
      return _pointsCache[filePath]!;
    }
    final points = await _loadLocationFile(filePath);
    _pointsCache[filePath] = points;
    return points;
  }
  
  static Future<List<LocationPoint>> _loadLocationFile(String filePath) async {
    final file = File(filePath);
    final jsonString = await file.readAsString();
    final decoded = jsonDecode(jsonString);
    
    return LocationPoint.parseAnyJson(decoded);
  }

  static void updateCache(String filePath, List<LocationPoint> points) {
    _pointsCache[filePath] = List<LocationPoint>.from(points);
  }

  static void invalidateCache(String filePath) {
    _pointsCache.remove(filePath);
  }

  static void clearCache() {
    _pointsCache.clear();
  }
  
  /// Calculate statistics for a set of points
  static Map<String, dynamic> calculateStatistics(List<LocationPoint> points) {
    if (points.isEmpty) {
      return {
        'pointCount': 0,
        'distance': 0.0,
        'duration': Duration.zero,
      };
    }
    
    double totalDistance = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final dx = p2.latitude - p1.latitude;
      final dy = p2.longitude - p1.longitude;
      totalDistance += (dx * dx + dy * dy);
    }
    
    final duration = points.last.timestamp.difference(points.first.timestamp);
    
    return {
      'pointCount': points.length,
      'distance': totalDistance,
      'duration': duration,
      'startTime': points.first.timestamp,
      'endTime': points.last.timestamp,
    };
  }
}
