import 'dart:convert';
import 'package:latlong2/latlong.dart';

class FavoriteRoad {
  final String id;
  final String name;
  final List<LatLng> points;
  final double distanceMeters;
  final DateTime createdAt;

  FavoriteRoad({
    required this.id,
    required this.name,
    required this.points,
    required this.distanceMeters,
    required this.createdAt,
  });

  Map<String, dynamic> toJsonMap() {
    return {
      'id': id,
      'name': name,
      'points': points.map((p) => [p.latitude, p.longitude]).toList(),
      'distanceMeters': distanceMeters,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  String toJson() => jsonEncode(toJsonMap());

  factory FavoriteRoad.fromJsonMap(Map<String, dynamic> map) {
    final rawPts = map['points'] as List? ?? [];
    final List<LatLng> pts = [];
    for (final pt in rawPts) {
      if (pt is List && pt.length >= 2) {
        pts.add(LatLng((pt[0] as num).toDouble(), (pt[1] as num).toDouble()));
      }
    }
    return FavoriteRoad(
      id: map['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: map['name'] as String? ?? 'Favorite Road',
      points: pts,
      distanceMeters: (map['distanceMeters'] as num?)?.toDouble() ?? 0.0,
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  factory FavoriteRoad.fromJson(String jsonStr) =>
      FavoriteRoad.fromJsonMap(jsonDecode(jsonStr));
}
