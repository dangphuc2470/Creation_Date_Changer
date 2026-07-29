import 'dart:io';
import 'package:latlong2/latlong.dart';

class MapImage {
  final String path;
  final String name;
  final DateTime dateTaken;
  LatLng? gpsLocation; // The location displayed on the map
  bool isManual; // true if manually dragged by the user
  final bool hasOriginalGps;
  bool isGeotagged;

  MapImage({
    required this.path,
    required this.name,
    required this.dateTaken,
    this.gpsLocation,
    this.isManual = false,
    this.hasOriginalGps = false,
    this.isGeotagged = false,
  });

  File get file => File(path);
}
