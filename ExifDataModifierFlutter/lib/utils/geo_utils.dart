import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/location_point.dart';

/// Simple bounding box for map bounds
class BoundingBox {
  final LatLng southWest;
  final LatLng northEast;
  
  const BoundingBox(this.southWest, this.northEast);
  
  LatLng get center => LatLng(
    (southWest.latitude + northEast.latitude) / 2,
    (southWest.longitude + northEast.longitude) / 2,
  );
}

class GeoUtils {
  static const Distance _distance = Distance();
  
  /// Calculate distance between two points in meters using Haversine formula
  static double distanceBetween(LatLng point1, LatLng point2) {
    return _distance.as(LengthUnit.Meter, point1, point2);
  }
  
  /// Calculate total distance of a track
  static double calculateTrackDistance(List<LocationPoint> points) {
    if (points.length < 2) return 0.0;
    
    double totalDistance = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      totalDistance += distanceBetween(points[i].latLng, points[i + 1].latLng);
    }
    return totalDistance;
  }
  
  /// Calculate bounding box for a list of points
  static BoundingBox calculateBounds(List<LocationPoint> points) {
    if (points.isEmpty) {
      return const BoundingBox(LatLng(0, 0), LatLng(0, 0));
    }
    
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;
    
    for (final point in points) {
      minLat = min(minLat, point.latitude);
      maxLat = max(maxLat, point.latitude);
      minLon = min(minLon, point.longitude);
      maxLon = max(maxLon, point.longitude);
    }
    
    return BoundingBox(
      LatLng(minLat, minLon),
      LatLng(maxLat, maxLon),
    );
  }
  
  /// Find nearest location point to a given timestamp using binary search
  /// Optimized for geotagging photos
  static LocationPoint? findNearestByTime(
    List<LocationPoint> points,
    DateTime targetTime, {
    Duration maxTimeDifference = const Duration(hours: 1),
  }) {
    if (points.isEmpty) return null;
    
    // Binary search for closest timestamp
    int left = 0;
    int right = points.length - 1;
    
    while (left < right) {
      int mid = (left + right) ~/ 2;
      if (points[mid].timestamp.isBefore(targetTime)) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    
    // Check the closest point and its neighbors
    LocationPoint? closest;
    Duration? closestDiff;
    
    for (int i = max(0, left - 1); i <= min(points.length - 1, left + 1); i++) {
      final diff = (points[i].timestamp.difference(targetTime)).abs();
      if (closestDiff == null || diff < closestDiff) {
        closestDiff = diff;
        closest = points[i];
      }
    }
    
    // Check if within max time difference
    if (closestDiff != null && closestDiff <= maxTimeDifference) {
      return closest;
    }
    
    return null;
  }
  
  /// Simplify track using Douglas-Peucker algorithm
  static List<LocationPoint> simplifyTrack(
    List<LocationPoint> points,
    double epsilon,
  ) {
    if (points.length < 3) return points;
    
    return _douglasPeucker(points, epsilon);
  }
  
  static List<LocationPoint> _douglasPeucker(
    List<LocationPoint> points,
    double epsilon,
  ) {
    double maxDistance = 0;
    int index = 0;
    
    for (int i = 1; i < points.length - 1; i++) {
      double distance = _perpendicularDistance(
        points[i].latLng,
        points.first.latLng,
        points.last.latLng,
      );
      
      if (distance > maxDistance) {
        maxDistance = distance;
        index = i;
      }
    }
    
    if (maxDistance > epsilon) {
      final left = _douglasPeucker(points.sublist(0, index + 1), epsilon);
      final right = _douglasPeucker(points.sublist(index), epsilon);
      
      return [...left.sublist(0, left.length - 1), ...right];
    } else {
      return [points.first, points.last];
    }
  }
  
  static double _perpendicularDistance(
    LatLng point,
    LatLng lineStart,
    LatLng lineEnd,
  ) {
    final x0 = point.latitude;
    final y0 = point.longitude;
    final x1 = lineStart.latitude;
    final y1 = lineStart.longitude;
    final x2 = lineEnd.latitude;
    final y2 = lineEnd.longitude;
    
    final numerator = ((y2 - y1) * x0 - (x2 - x1) * y0 + x2 * y1 - y2 * x1).abs();
    final denominator = sqrt(pow(y2 - y1, 2) + pow(x2 - x1, 2));

    return denominator == 0 ? 0.0 : numerator / denominator;
  }

  /// Find nearest point on a polyline for projecting places onto favorite roads
  static PolylineProjection findClosestOnPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) {
      return PolylineProjection(insertIndex: 0, projectedPoint: point, distanceMeters: 0, t: 0);
    }
    if (polyline.length == 1) {
      return PolylineProjection(
        insertIndex: 0,
        projectedPoint: polyline.first,
        distanceMeters: distanceBetween(point, polyline.first),
        t: 0,
      );
    }

    double minDistance = double.infinity;
    int bestSegmentIdx = 0;
    LatLng bestProjPoint = polyline.first;
    double bestT = 0.0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];

      final x0 = point.latitude, y0 = point.longitude;
      final x1 = a.latitude, y1 = a.longitude;
      final x2 = b.latitude, y2 = b.longitude;

      final dx = x2 - x1, dy = y2 - y1;
      final lenSq = dx * dx + dy * dy;

      double t = 0.0;
      if (lenSq > 0) {
        t = ((x0 - x1) * dx + (y0 - y1) * dy) / lenSq;
        t = t.clamp(0.0, 1.0);
      }

      final projLat = x1 + t * dx;
      final projLng = y1 + t * dy;
      final projPt = LatLng(projLat, projLng);
      final dist = distanceBetween(point, projPt);

      if (dist < minDistance) {
        minDistance = dist;
        bestSegmentIdx = i;
        bestProjPoint = projPt;
        bestT = t;
      }
    }

    return PolylineProjection(
      insertIndex: bestSegmentIdx,
      projectedPoint: bestProjPoint,
      distanceMeters: minDistance,
      t: bestT,
    );
  }
}

class PolylineProjection {
  final int insertIndex;
  final LatLng projectedPoint;
  final double distanceMeters;
  final double t;

  PolylineProjection({
    required this.insertIndex,
    required this.projectedPoint,
    required this.distanceMeters,
    required this.t,
  });
}
