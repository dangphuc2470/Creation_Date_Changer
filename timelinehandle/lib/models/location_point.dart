import 'package:latlong2/latlong.dart';

/// Represents a single GPS location point with timestamp
class LocationPoint {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? elevation;
  final String? activityType;

  LocationPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.elevation,
    this.activityType,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  /// Create from JSON (Timeline.json format)
  factory LocationPoint.fromTimelineJson(Map<String, dynamic> json) {
    final pointStr = json['point'] as String;
    final parts = pointStr.split('°, ');
    final lat = double.parse(parts[0]);
    final lon = double.parse(parts[1].replaceAll('°', ''));

    return LocationPoint(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.parse(json['time']),
    );
  }

  /// Create from GPX trkpt element
  factory LocationPoint.fromGpx({
    required double lat,
    required double lon,
    required DateTime time,
    double? ele,
  }) {
    return LocationPoint(
      latitude: lat,
      longitude: lon,
      timestamp: time,
      elevation: ele,
    );
  }

  /// Convert to simplified JSON for geotagging
  Map<String, dynamic> toGeotagJson([double? offset]) {
    String timeStr;
    if (offset != null && offset != 0) {
      // Create a local-looking time by adding offset to UTC
      final adjustedTime =
          timestamp.toUtc().add(Duration(minutes: (offset * 60).toInt()));
      String isoStr = adjustedTime.toIso8601String();

      // Remove 'Z' if it exists to append our own offset
      if (isoStr.endsWith('Z')) {
        isoStr = isoStr.substring(0, isoStr.length - 1);
      }
      timeStr = isoStr + _formatOffset(offset);
    } else {
      timeStr = timestamp.toUtc().toIso8601String();
    }

    return {
      'time': timeStr,
      'lat': latitude,
      'lon': longitude,
      if (elevation != null) 'ele': elevation,
    };
  }

  String _formatOffset(double offset) {
    final absOffset = offset.abs();
    final hours = absOffset.floor();
    final minutes = ((absOffset - hours) * 60).round();
    final sign = offset >= 0 ? '+' : '-';
    return '$sign${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }

  /// Create from geotag JSON
  factory LocationPoint.fromGeotagJson(Map<String, dynamic> json) {
    return LocationPoint(
      latitude: json['lat'] as double,
      longitude: json['lon'] as double,
      timestamp: DateTime.parse(json['time'] as String),
      elevation: json['ele'] as double?,
    );
  }
}
