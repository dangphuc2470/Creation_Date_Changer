import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../models/location_point.dart';
import 'package:native_exif/native_exif.dart';

class GeotagItem {
  final File file;
  final String path;
  final String filename;
  LocationPoint? location;
  bool isError;
  bool isSuccess;

  GeotagItem({
    required this.file,
    required this.path,
    required this.filename,
    this.location,
    this.isError = false,
    this.isSuccess = false,
  });
}

class GeotagProvider extends ChangeNotifier {
  List<GeotagItem> items = [];
  List<LocationPoint> timelineLocations = [];
  bool isProcessing = false;
  Duration timeOffset = Duration.zero; // For adjusting match times

  // Selected location from map point or manual entry
  LocationPoint? currentLocationOverride;

  void addFiles(List<File> files) {
    for (var file in files) {
      if (!items.any((item) => item.path == file.path)) {
        items.add(GeotagItem(
          file: file,
          path: file.path,
          filename: file.uri.pathSegments.last,
        ));
      }
    }
    _matchLocations();
  }

  void removeFile(GeotagItem item) {
    items.remove(item);
    notifyListeners();
  }

  void clearFiles() {
    items.clear();
    notifyListeners();
  }

  void setCurrentLocationOverride(double lat, double lng) {
    currentLocationOverride = LocationPoint(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );
    notifyListeners();
  }

  /// Load Timeline JSON exported from the timelinehandle app
  Future<void> loadTimelineData(String jsonData) async {
    try {
      final List<dynamic> parsedList = jsonDecode(jsonData);
      timelineLocations = parsedList.map((e) => LocationPoint.fromGeotagJson(e)).toList();
      // Ensure sorted
      timelineLocations.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _matchLocations();
    } catch (e) {
      // Handle error gracefully
    }
  }

  void setTimeOffset(Duration offset) {
    timeOffset = offset;
    _matchLocations();
  }

  Future<void> _matchLocations() async {
    for (var item in items) {
      if (currentLocationOverride != null) {
        item.location = currentLocationOverride;
        item.isError = false;
        continue;
      }

      if (timelineLocations.isEmpty) continue;

      try {
        final stat = await item.file.stat();
        // Use modified as approximation for taken if EXIF not read yet
        DateTime fileTime = stat.modified.add(timeOffset);
        
        // Find closest location point in time
        // Simple linear search for now, could be binary search optimized
        LocationPoint? closest;
        Duration minDiff = const Duration(days: 9999);

        for (var loc in timelineLocations) {
          final diff = loc.timestamp.difference(fileTime).abs();
          if (diff < minDiff) {
            minDiff = diff;
            closest = loc;
          }
        }

        // Only assign if within reasonable threshold, say 30 minutes
        if (closest != null && minDiff.inMinutes <= 30) {
          item.location = closest;
          item.isError = false;
        } else {
          item.location = null;
          item.isError = true;
        }
      } catch (e) {
        item.isError = true;
      }
    }
    notifyListeners();
  }

  Future<void> applyChanges() async {
    isProcessing = true;
    notifyListeners();

    for (var item in items) {
      if (item.location != null && !item.isError) {
        try {
          final exif = await Exif.fromPath(item.path);
          
          await exif.writeAttributes({
            'GPSLatitude': item.location!.latitude.abs().toString(),
            'GPSLatitudeRef': item.location!.latitude >= 0 ? 'N' : 'S',
            'GPSLongitude': item.location!.longitude.abs().toString(),
            'GPSLongitudeRef': item.location!.longitude >= 0 ? 'E' : 'W',
          });
          
          await exif.close();
          item.isSuccess = true;
        } catch (e) {
          item.isError = true;
          item.isSuccess = false;
        }
      }
    }

    isProcessing = false;
    notifyListeners();
  }
}
