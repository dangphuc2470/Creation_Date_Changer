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

  /// Convert to a GeoJSON Feature Map
  Map<String, dynamic> toGeoJsonFeature([double? offset]) {
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
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [
          longitude,
          latitude,
          if (elevation != null) elevation,
        ],
      },
      'properties': {
        'time': timeStr,
        if (activityType != null) 'activityType': activityType,
      },
    };
  }

  /// Convert a list of points to a GeoJSON FeatureCollection
  static Map<String, dynamic> toGeoJson(List<LocationPoint> points, [double? offset, String state = 'original', String source = 'merge']) {
    return {
      'type': 'FeatureCollection',
      'properties': {
        'state': state,
        'source': source,
      },
      'features': points.map((p) => p.toGeoJsonFeature(offset)).toList(),
    };
  }

  /// Create from GeoJSON Feature Map
  static LocationPoint? fromGeoJsonFeature(Map<String, dynamic> feature) {
    try {
      final geometry = feature['geometry'] as Map<String, dynamic>?;
      if (geometry == null) return null;

      final geomType = geometry['type'] as String?;
      if (geomType != 'Point') return null;

      final coordinates = geometry['coordinates'] as List?;
      if (coordinates == null || coordinates.length < 2) return null;

      final lon = (coordinates[0] as num).toDouble();
      final lat = (coordinates[1] as num).toDouble();
      final ele = coordinates.length >= 3 ? (coordinates[2] as num?)?.toDouble() : null;

      final properties = feature['properties'] as Map<String, dynamic>? ?? {};
      final timeStr = properties['time'] as String?;
      if (timeStr == null) return null;

      return LocationPoint(
        latitude: lat,
        longitude: lon,
        timestamp: DateTime.parse(timeStr),
        elevation: ele,
        activityType: properties['activityType'] as String?,
      );
    } catch (e) {
      return null;
    }
  }

  /// Create a list of LocationPoints from a GeoJSON FeatureCollection or single Feature Map
  static List<LocationPoint> fromGeoJson(Map<String, dynamic> json) {
    final List<LocationPoint> points = [];
    final type = json['type'] as String?;
    
    if (type == 'FeatureCollection') {
      final features = json['features'] as List? ?? [];
      for (final feature in features) {
        if (feature is Map<String, dynamic>) {
          final pt = LocationPoint.fromGeoJsonFeature(feature);
          if (pt != null) {
            points.add(pt);
          }
        }
      }
    } else if (type == 'Feature') {
      final pt = LocationPoint.fromGeoJsonFeature(json);
      if (pt != null) {
        points.add(pt);
      }
    }
    return points;
  }

  /// Parse any JSON format (either GeoJSON Map or old Geotag JSON list format)
  static List<LocationPoint> parseAnyJson(dynamic decodedJson) {
    if (decodedJson is Map<String, dynamic>) {
      return fromGeoJson(decodedJson);
    } else if (decodedJson is List) {
      return decodedJson
          .map((e) {
            try {
              if (e is Map<String, dynamic>) {
                if (e['type'] == 'Feature') {
                  return fromGeoJsonFeature(e);
                }
                return LocationPoint.fromGeotagJson(e);
              }
            } catch (_) {}
            return null;
          })
          .whereType<LocationPoint>()
          .toList();
    }
    return [];
  }
}
