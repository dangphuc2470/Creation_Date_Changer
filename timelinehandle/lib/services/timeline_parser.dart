import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import '../models/location_point.dart';
import '../models/timeline_segment.dart';

/// Parameters for the isolate parser
class _ParseParams {
  final String filePath;
  final DateTime? startDate;
  final DateTime endDate;
  final SendPort sendPort;

  _ParseParams({
    required this.filePath,
    this.startDate,
    required this.endDate,
    required this.sendPort,
  });
}

/// Progress update message
class ParseProgress {
  final double progress;
  final String message;

  ParseProgress(this.progress, this.message);
}

/// Service to parse Google Timeline JSON files
class TimelineParser {
  /// Parse Timeline.json file with time filtering
  /// Returns a stream of location points
  static Future<List<LocationPoint>> parseFile({
    required String filePath,
    DateTime? startDate,
    DateTime? endDate,
    Function(ParseProgress)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final params = _ParseParams(
      filePath: filePath,
      startDate: startDate,
      endDate: endDate ?? DateTime.now(),
      sendPort: receivePort.sendPort,
    );

    // Spawn isolate for background parsing
    await Isolate.spawn(_parseInIsolate, params);

    final List<LocationPoint> allPoints = [];
    
    await for (final message in receivePort) {
      if (message is ParseProgress) {
        onProgress?.call(message);
      } else if (message is List<LocationPoint>) {
        allPoints.addAll(message);
      } else if (message == 'done') {
        receivePort.close();
        break;
      } else if (message is String && message.startsWith('error:')) {
        receivePort.close();
        throw Exception(message.substring(6));
      }
    }

    return allPoints;
  }

  /// Isolate worker function
  static void _parseInIsolate(_ParseParams params) async {
    try {
      final file = File(params.filePath);
      
      params.sendPort.send(ParseProgress(0.0, 'Reading file...'));
      
      // Read file as string
      final jsonString = await file.readAsString();
      
      params.sendPort.send(ParseProgress(0.3, 'Parsing JSON...'));
      
      // Parse JSON
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      final semanticSegments = jsonData['semanticSegments'] as List? ?? [];
      
      params.sendPort.send(ParseProgress(0.4, 'Filtering segments...'));
      
      final List<LocationPoint> points = [];
      int processedCount = 0;
      
      for (final segmentJson in semanticSegments) {
        try {
          final segment = TimelineSegment.fromTimelineJson(segmentJson);
          
          // Filter by date range
          if (params.startDate != null && segment.endTime.isBefore(params.startDate!)) {
            continue;
          }
          if (segment.startTime.isAfter(params.endDate)) {
            continue;
          }
          
          // Add points from this segment
          points.addAll(segment.points);
          
          processedCount++;
          if (processedCount % 100 == 0) {
            final progress = 0.4 + (processedCount / semanticSegments.length) * 0.5;
            params.sendPort.send(ParseProgress(
              progress,
              'Processed $processedCount/${semanticSegments.length} segments...',
            ));
          }
        } catch (e) {
          // Skip malformed segments
          if (kDebugMode) {
            print('Error parsing segment: $e');
          }
        }
      }
      
      params.sendPort.send(ParseProgress(0.9, 'Sorting points...'));
      
      // Sort by timestamp
      points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      params.sendPort.send(ParseProgress(1.0, 'Complete! ${points.length} points'));
      params.sendPort.send(points);
      params.sendPort.send('done');
    } catch (e) {
      params.sendPort.send('error: $e');
      params.sendPort.send('done');
    }
  }
}
