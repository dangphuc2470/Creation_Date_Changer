import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import '../models/location_point.dart';
import 'timeline_parser.dart';
import 'gpx_parser.dart';

class FileMetadata {
  final String filePath;
  final String fileName;
  final List<LocationPoint> points;
  final DateTime startTime;
  final DateTime endTime;

  FileMetadata({
    required this.filePath,
    required this.fileName,
    required this.points,
    required this.startTime,
    required this.endTime,
  });
}

class GroupedFile {
  final FileMetadata metadata;
  bool isSelected;

  GroupedFile(this.metadata, {this.isSelected = true});

  String get fileName => metadata.fileName;
  String get filePath => metadata.filePath;
  List<LocationPoint> get points => metadata.points;
  DateTime get startTime => metadata.startTime;
  DateTime get endTime => metadata.endTime;
}

class FileGroup {
  final String date;
  final List<GroupedFile> files;

  FileGroup({required this.date, required this.files});

  bool get hasConflict {
    if (files.length <= 1) return false;

    // Check for point-level conflicts: same timestamp, different location
    final Map<DateTime, LocationPoint> observedPoints = {};

    for (final file in files) {
      // Filter points to only those belonging to this group's date
      final dayPoints = file.points
          .where((p) => DateFormat('yyyy-MM-dd').format(p.timestamp) == date);

      for (final p in dayPoints) {
        final existing = observedPoints[p.timestamp];
        if (existing != null) {
          // Conflict if same time but different location
          if (existing.latitude != p.latitude ||
              existing.longitude != p.longitude) {
            return true;
          }
        } else {
          observedPoints[p.timestamp] = p;
        }
      }
    }

    return false;
  }
}

class BatchImportService {
  static String _formatDate(DateTime date, [double? timezoneOffset]) {
    final localTime = (timezoneOffset != null && timezoneOffset != 0)
        ? date.toUtc().add(Duration(minutes: (timezoneOffset * 60).toInt()))
        : date.toLocal();
    return DateFormat('yyyy-MM-dd').format(localTime);
  }

  static Future<List<FileGroup>> scanDirectory(
    String dirPath,
    Function(double progress, String message)? onProgress, [
    double? timezoneOffset,
  ]) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];

    final entities = await dir.list(recursive: false).toList();
    final List<File> relevantFiles = [];

    for (final entity in entities) {
      if (entity is File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (ext == '.json' || ext == '.gpx') {
          relevantFiles.add(entity);
        }
      }
    }

    if (relevantFiles.isEmpty) return [];

    final Map<String, List<GroupedFile>> groupsByDate = {};

    for (int i = 0; i < relevantFiles.length; i++) {
      final file = relevantFiles[i];
      final progress = i / relevantFiles.length;
      onProgress?.call(progress, 'Parsing ${path.basename(file.path)}...');

      try {
        final ext = path.extension(file.path).toLowerCase();
        List<LocationPoint> points = [];

        if (ext == '.json') {
          points = await TimelineParser.parseFile(filePath: file.path);
        } else {
          points = await GpxParser.parseFile(file.path);
        }

        if (points.isNotEmpty) {
          final startTime = points.first.timestamp;
          final endTime = points.last.timestamp;

          final metadata = FileMetadata(
            filePath: file.path,
            fileName: path.basename(file.path),
            points: points,
            startTime: startTime,
            endTime: endTime,
          );

          // Group by all dates covered by the file
          final Set<String> coveredDates = {};
          for (final p in points) {
            coveredDates.add(_formatDate(p.timestamp, timezoneOffset));
          }

          for (final dateKey in coveredDates) {
            groupsByDate
                .putIfAbsent(dateKey, () => [])
                .add(GroupedFile(metadata));
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error parsing ${file.path}: $e');
        }
      }
    }

    onProgress?.call(1.0, 'Scan complete');

    final result = groupsByDate.entries
        .map((e) => FileGroup(date: e.key, files: e.value))
        .toList();

    // Sort by date
    result.sort((a, b) => a.date.compareTo(b.date));

    return result;
  }

  /// Merge points from selected files in a group
  static List<LocationPoint> mergeGroup(FileGroup group, [double? timezoneOffset]) {
    final List<LocationPoint> allPoints = [];
    for (final file in group.files) {
      if (file.isSelected) {
        // Only include points that match this group's date
        allPoints.addAll(
            file.points.where((p) => _formatDate(p.timestamp, timezoneOffset) == group.date));
      }
    }

    // Sort and deduplicate if necessary
    allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Simple deduplication by timestamp
    if (allPoints.isEmpty) return [];

    final List<LocationPoint> uniquePoints = [allPoints.first];
    for (int i = 1; i < allPoints.length; i++) {
      if (allPoints[i].timestamp != allPoints[i - 1].timestamp) {
        uniquePoints.add(allPoints[i]);
      }
    }

    return uniquePoints;
  }
}
