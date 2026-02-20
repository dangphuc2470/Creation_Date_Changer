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
  Map<String, dynamic> toGeotagJson() {
    return {
      'time': timestamp.toIso8601String(),
      'lat': latitude,
      'lon': longitude,
      if (elevation != null) 'ele': elevation,
    };
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
