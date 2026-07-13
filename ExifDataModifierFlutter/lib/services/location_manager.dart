import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/location_point.dart';

class DateInfo {
  final DateTime date;
  final int pointCount;
  final String filePath;
  
  DateInfo({
    required this.date,
    required this.pointCount,
    required this.filePath,
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
    
    // Scan Year/Month/Day structure
    await for (final yearEntity in rootDir.list()) {
      if (yearEntity is! Directory) continue;
      
      final yearName = path.basename(yearEntity.path);
      final year = int.tryParse(yearName);
      if (year == null) continue;
      
      await for (final monthEntity in yearEntity.list()) {
        if (monthEntity is! Directory) continue;
        
        final monthName = path.basename(monthEntity.path);
        final month = int.tryParse(monthName);
        if (month == null) continue;
        
        await for (final dayEntity in monthEntity.list()) {
          if (dayEntity is! Directory) continue;
          
          final dayName = path.basename(dayEntity.path);
          final day = int.tryParse(dayName);
          if (day == null) continue;
          
          // Check for locations.json
          final locationsFile = File(path.join(dayEntity.path, 'locations.json'));
          if (await locationsFile.exists()) {
            final points = await _loadLocationFile(locationsFile.path);
            dates.add(DateInfo(
              date: DateTime(year, month, day),
              pointCount: points.length,
              filePath: locationsFile.path,
            ));
          }
        }
      }
    }
    
    // Also check for date range files
    await for (final entity in rootDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final points = await _loadLocationFile(entity.path);
        if (points.isNotEmpty) {
          dates.add(DateInfo(
            date: points.first.timestamp,
            pointCount: points.length,
            filePath: entity.path,
          ));
        }
      }
    }
    
    // Sort by date
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
