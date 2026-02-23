import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import '../models/location_point.dart';
import '../models/export_config.dart';

/// Service to export location data in organized folder structures
class ExportService {
  /// Export location points according to configuration
  static Future<ExportResult> export({
    required List<LocationPoint> points,
    required ExportConfig config,
    Function(double progress, String message)? onProgress,
  }) async {
    onProgress?.call(0.0, 'Preparing export...');

    // Filter points by date range
    final filteredPoints = points.where((point) {
      if (config.startDate != null &&
          point.timestamp.isBefore(config.startDate!)) {
        return false;
      }
      if (point.timestamp.isAfter(config.endDate)) {
        return false;
      }
      return true;
    }).toList();

    onProgress?.call(0.1, 'Filtered ${filteredPoints.length} points');

    if (config.mode == ExportMode.yearMonthDay) {
      return await _exportYearMonthDay(filteredPoints, config, onProgress);
    } else if (config.mode == ExportMode.dailyFiles) {
      return await _exportDailyFiles(filteredPoints, config, onProgress);
    } else {
      return await _exportDateRange(filteredPoints, config, onProgress);
    }
  }

  /// Export each day as a separate file in a single folder
  static Future<ExportResult> _exportDailyFiles(
    List<LocationPoint> points,
    ExportConfig config,
    Function(double progress, String message)? onProgress,
  ) async {
    // Group points by date
    final Map<String, List<LocationPoint>> pointsByDate = {};

    for (final point in points) {
      final adjustedTime = point.timestamp
          .add(Duration(minutes: (config.timezoneOffset * 60).toInt()));
      final dateKey = DateFormat('yyyy-MM-dd').format(adjustedTime);
      pointsByDate.putIfAbsent(dateKey, () => []).add(point);
    }

    onProgress?.call(0.2, 'Grouped into ${pointsByDate.length} days');

    int filesCreated = 0;
    int totalDays = pointsByDate.length;

    // Create output directory
    await Directory(config.outputPath).create(recursive: true);

    for (final entry in pointsByDate.entries) {
      final dateStr = entry.key;
      final dayPoints = entry.value;

      // Write YYYY-MM-DD.json
      final filePath = path.join(config.outputPath, '$dateStr.json');
      await _writeLocationsFile(filePath, dayPoints, config.timezoneOffset);

      filesCreated++;
      final progress = 0.2 + (filesCreated / totalDays) * 0.8;
      onProgress?.call(progress, 'Exported $filesCreated/$totalDays files');
    }

    return ExportResult(
      filesCreated: filesCreated,
      pointsExported: points.length,
      outputPath: config.outputPath,
    );
  }

  /// Export with Year/Month/Day folder structure
  static Future<ExportResult> _exportYearMonthDay(
    List<LocationPoint> points,
    ExportConfig config,
    Function(double progress, String message)? onProgress,
  ) async {
    // Group points by date
    final Map<String, List<LocationPoint>> pointsByDate = {};

    for (final point in points) {
      final adjustedTime = point.timestamp
          .add(Duration(minutes: (config.timezoneOffset * 60).toInt()));
      final dateKey = DateFormat('yyyy-MM-dd').format(adjustedTime);
      pointsByDate.putIfAbsent(dateKey, () => []).add(point);
    }

    onProgress?.call(0.2, 'Grouped into ${pointsByDate.length} days');

    int filesCreated = 0;
    int totalDays = pointsByDate.length;

    for (final entry in pointsByDate.entries) {
      final date = DateTime.parse(entry.key);
      final dayPoints = entry.value;

      // Create folder structure: Year/Month/Day
      final yearFolder = path.join(config.outputPath, date.year.toString());
      final monthFolder =
          path.join(yearFolder, date.month.toString().padLeft(2, '0'));
      final dayFolder =
          path.join(monthFolder, date.day.toString().padLeft(2, '0'));

      await Directory(dayFolder).create(recursive: true);

      // Write locations.json
      final filePath = path.join(dayFolder, 'locations.json');
      await _writeLocationsFile(filePath, dayPoints, config.timezoneOffset);

      filesCreated++;
      final progress = 0.2 + (filesCreated / totalDays) * 0.8;
      onProgress?.call(progress, 'Exported $filesCreated/$totalDays days');
    }

    return ExportResult(
      filesCreated: filesCreated,
      pointsExported: points.length,
      outputPath: config.outputPath,
    );
  }

  /// Export as single file for date range
  static Future<ExportResult> _exportDateRange(
    List<LocationPoint> points,
    ExportConfig config,
    Function(double progress, String message)? onProgress,
  ) async {
    if (points.isEmpty) {
      throw Exception('No points to export in the specified date range');
    }

    // Create output directory
    await Directory(config.outputPath).create(recursive: true);

    // Generate filename
    final startDate = config.startDate ?? points.first.timestamp;
    final endDate = config.endDate;

    // Adjust for filename display
    final adjStart =
        startDate.add(Duration(minutes: (config.timezoneOffset * 60).toInt()));
    final adjEnd =
        endDate.add(Duration(minutes: (config.timezoneOffset * 60).toInt()));

    final startStr = DateFormat('yyyy-MM-dd').format(adjStart);
    final endStr = DateFormat('yyyy-MM-dd').format(adjEnd);
    final filename = '${startStr}_to_$endStr.json';
    final filePath = path.join(config.outputPath, filename);

    onProgress?.call(0.5, 'Writing file...');

    await _writeLocationsFile(filePath, points, config.timezoneOffset);

    onProgress?.call(1.0, 'Export complete');

    return ExportResult(
      filesCreated: 1,
      pointsExported: points.length,
      outputPath: filePath,
    );
  }

  /// Write location points to JSON file (optimized for geotagging)
  static Future<void> _writeLocationsFile(
    String filePath,
    List<LocationPoint> points,
    double timezoneOffset,
  ) async {
    // Sort by timestamp for efficient binary search
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Convert to simplified JSON format
    final jsonList = points.map((p) => p.toGeotagJson(timezoneOffset)).toList();

    // Write to file
    final file = File(filePath);
    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonList);
    await file.writeAsString(jsonString);
  }
}

/// Result of an export operation
class ExportResult {
  final int filesCreated;
  final int pointsExported;
  final String outputPath;

  ExportResult({
    required this.filesCreated,
    required this.pointsExported,
    required this.outputPath,
  });
}
