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
  /// Scan exported folder and get list of available dates
  static Future<List<DateInfo>> scanExportedData(String rootPath) async {
    final List<DateInfo> dates = [];
    final rootDir = Directory(rootPath);
    
    if (!await rootDir.exists()) {
      return dates;
    }

    final originalDir = Directory(rootPath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    ));
    
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
          final jsonString = await entity.readAsString();
          final decoded = jsonDecode(jsonString);
          final points = LocationPoint.parseAnyJson(decoded);
          
          final distance = GeoUtils.calculateTrackDistance(points);

          // Extract state & source from GeoJSON properties
          String state = 'original';
          String source = 'merge';
          if (decoded is Map<String, dynamic>) {
            final properties = decoded['properties'] as Map<String, dynamic>? ?? {};
            state = properties['state'] as String? ?? 'original';
            source = properties['source'] as String? ?? 'merge';
          }
          
          // Check for backups in original folder
          bool hasTimeline = false;
          bool hasGpx = false;
          if (await originalDir.exists()) {
            hasTimeline = await File(path.join(originalDir.path, '${dateStr}_timeline.json')).exists();
            hasGpx = await File(path.join(originalDir.path, '${dateStr}_gpx.json')).exists();
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
        } catch (e) {
          if (kDebugMode) {
            print('Error scanning file ${entity.path}: $e');
          }
        }
      }
    }
    
    // Sort by date descending
    dates.sort((a, b) => b.date.compareTo(a.date));
    
    return dates;
  }
  
  /// Load location points from a file
  static Future<List<LocationPoint>> loadLocationFile(String filePath) async {
    return await _loadLocationFile(filePath);
  }
  
  static Future<List<LocationPoint>> _loadLocationFile(String filePath) async {
    final file = File(filePath);
    final jsonString = await file.readAsString();
    final decoded = jsonDecode(jsonString);
    
    return LocationPoint.parseAnyJson(decoded);
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
