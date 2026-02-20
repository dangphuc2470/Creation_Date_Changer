import 'location_point.dart';

enum SegmentType {
  activity,
  visit,
}

/// Represents a timeline segment (activity or visit)
class TimelineSegment {
  final DateTime startTime;
  final DateTime endTime;
  final List<LocationPoint> points;
  final SegmentType type;
  final String? activityType;
  final String? placeId;

  TimelineSegment({
    required this.startTime,
    required this.endTime,
    required this.points,
    required this.type,
    this.activityType,
    this.placeId,
  });

  Duration get duration => endTime.difference(startTime);

  /// Create from Timeline.json semantic segment
  factory TimelineSegment.fromTimelineJson(Map<String, dynamic> json) {
    final startTime = DateTime.parse(json['startTime']);
    final endTime = DateTime.parse(json['endTime']);
    
    List<LocationPoint> points = [];
    SegmentType type;
    String? activityType;
    String? placeId;

    if (json.containsKey('activity')) {
      type = SegmentType.activity;
      final activity = json['activity'];
      activityType = activity['topCandidate']?['type'];
      
      // Extract start and end points
      if (activity['start']?['latLng'] != null) {
        final startLatLng = activity['start']['latLng'] as String;
        final parts = startLatLng.split('°, ');
        points.add(LocationPoint(
          latitude: double.parse(parts[0]),
          longitude: double.parse(parts[1].replaceAll('°', '')),
          timestamp: startTime,
          activityType: activityType,
        ));
      }
      
      if (activity['end']?['latLng'] != null) {
        final endLatLng = activity['end']['latLng'] as String;
        final parts = endLatLng.split('°, ');
        points.add(LocationPoint(
          latitude: double.parse(parts[0]),
          longitude: double.parse(parts[1].replaceAll('°', '')),
          timestamp: endTime,
          activityType: activityType,
        ));
      }
    } else if (json.containsKey('visit')) {
      type = SegmentType.visit;
      final visit = json['visit'];
      placeId = visit['topCandidate']?['placeId'];
      
      if (visit['topCandidate']?['placeLocation']?['latLng'] != null) {
        final latLng = visit['topCandidate']['placeLocation']['latLng'] as String;
        final parts = latLng.split('°, ');
        points.add(LocationPoint(
          latitude: double.parse(parts[0]),
          longitude: double.parse(parts[1].replaceAll('°', '')),
          timestamp: startTime,
        ));
      }
    } else {
      type = SegmentType.activity;
    }

    // Add timeline path points if available
    if (json.containsKey('timelinePath')) {
      final pathPoints = (json['timelinePath'] as List)
          .map((p) => LocationPoint.fromTimelineJson(p))
          .toList();
      points.addAll(pathPoints);
    }

    // Sort points by timestamp
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return TimelineSegment(
      startTime: startTime,
      endTime: endTime,
      points: points,
      type: type,
      activityType: activityType,
      placeId: placeId,
    );
  }
}
