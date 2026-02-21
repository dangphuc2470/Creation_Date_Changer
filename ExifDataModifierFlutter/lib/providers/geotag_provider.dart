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
  String? errorMessage; // Capture standard error message
  bool hasExistingGps; // True if loaded with GPS data already present
  bool isChecked;
  bool isManualLocation;

  GeotagItem({
    required this.file,
    required this.path,
    required this.filename,
    this.location,
    this.isError = false,
    this.isSuccess = false,
    this.errorMessage,
    this.hasExistingGps = false,
    this.isChecked = true,
    this.isManualLocation = false,
  });
}

class GeotagProvider extends ChangeNotifier {
  List<GeotagItem> items = [];
  List<LocationPoint> timelineLocations = [];
  bool isProcessing = false;
  int currentProcessing = 0;
  int totalProcessing = 0;
  Duration timeOffset = Duration.zero; // For adjusting match times

  bool overrideExistingGps = false;
  bool autoClearList = false;
  int maxInterpolationGapMinutes = 120; // Default 2 hours
  String? loadedTimelineFileName;
  LocationPoint? lastPinnedLocation;

  void setMaxInterpolationGapMinutes(int val) {
    maxInterpolationGapMinutes = val;
    _matchLocations();
  }

  void setOverrideExistingGps(bool value) {
    overrideExistingGps = value;
    _matchLocations();
    notifyListeners();
  }

  void setAutoClearList(bool value) {
    autoClearList = value;
    notifyListeners();
  }

  void toggleItemCheck(GeotagItem item, bool value) {
    item.isChecked = value;
    notifyListeners();
  }

  void checkAll() {
    for (var item in items) item.isChecked = true;
    notifyListeners();
  }

  void uncheckAll() {
    for (var item in items) item.isChecked = false;
    notifyListeners();
  }

  void selectOnlyErrors() {
    for (var item in items) {
      item.isChecked = item.isError;
    }
    notifyListeners();
  }

  void uncheckSuccess() {
    for (var item in items) {
      if (item.isSuccess) item.isChecked = false;
    }
    notifyListeners();
  }

  void _sortItems() {
    items.sort((a, b) {
      if (a.isError && !b.isError) return -1;
      if (!a.isError && b.isError) return 1;
      return a.filename.compareTo(b.filename);
    });
  }

  Future<void> addFiles(List<File> files) async {
    for (var file in files) {
      if (!items.any((item) => item.path == file.path)) {
        bool hasGps = false;
        try {
          if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
            final result = await Process.run('exiftool', ['-GPSLatitude', '-GPSLongitude', file.path]);
            if (result.stdout.toString().trim().isNotEmpty) {
              hasGps = true;
            }
          } else {
            final exif = await Exif.fromPath(file.path);
            final attr = await exif.getAttributes();
            if (attr != null && attr.containsKey('GPSLatitude') && attr.containsKey('GPSLongitude')) {
              hasGps = true;
            }
            await exif.close();
          }
        } catch (e) {
          // ignore error reading initial exif
        }
        
        items.add(GeotagItem(
          file: file,
          path: file.path,
          filename: file.uri.pathSegments.last,
          hasExistingGps: hasGps,
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
    lastPinnedLocation = null;
    notifyListeners();
  }

  void setCurrentLocationOverride(double lat, double lng) {
    lastPinnedLocation = LocationPoint(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );
    for (var item in items) {
      if (item.isChecked) {
        item.location = LocationPoint(
          latitude: lat,
          longitude: lng,
          timestamp: DateTime.now(),
        );
        item.isError = false;
        item.errorMessage = 'Manual Location applied';
        item.isManualLocation = true;
      }
    }
    _sortItems();
    notifyListeners();
  }

  /// Load Timeline JSON exported from the timelinehandle app
  Future<void> loadTimelineData(String jsonData, String filename) async {
    try {
      final List<dynamic> parsedList = jsonDecode(jsonData);
      timelineLocations = parsedList.map((e) => LocationPoint.fromGeotagJson(e)).toList();
      // Ensure sorted
      timelineLocations.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      loadedTimelineFileName = filename;
      _matchLocations();
    } catch (e) {
      // Handle error gracefully
      loadedTimelineFileName = null;
    }
  }

  void setTimeOffset(Duration offset) {
    timeOffset = offset;
    _matchLocations();
  }

  Future<void> _matchLocations() async {
    for (var item in items) {
      if (!overrideExistingGps && item.hasExistingGps) {
        item.isError = false;
        item.errorMessage = 'Has existing GPS (Not overridden)';
        item.location = null; // Do not apply new location
        continue;
      }

      if (item.isManualLocation) {
        continue;
      }

      if (timelineLocations.isEmpty) {
         if (!item.hasExistingGps || overrideExistingGps) {
           if (lastPinnedLocation != null) {
              item.location = LocationPoint(
                latitude: lastPinnedLocation!.latitude,
                longitude: lastPinnedLocation!.longitude,
                timestamp: DateTime.now(),
              );
              item.isError = false;
              item.errorMessage = 'Manual Location applied (Auto)';
              item.isManualLocation = true;
           } else {
             item.location = null; 
             item.isError = true;
             item.errorMessage = 'Waiting for timeline or map selection';
           }
         }
         continue;
      }

      try {
        final stat = await item.file.stat();
        // Use modified as approximation for taken if EXIF not read yet
        DateTime fileTime = stat.modified.add(timeOffset);
        
        // Find points for interpolation
        if (fileTime.isBefore(timelineLocations.first.timestamp)) {
          // File is older than our first timeline point
          final diff = timelineLocations.first.timestamp.difference(fileTime).abs();
          if (diff.inMinutes <= 30) {
            item.location = timelineLocations.first;
            item.isError = false;
            item.errorMessage = null;
          } else {
             item.location = null;
             item.isError = true;
             item.errorMessage = 'No nearest timeline location found within 30 minutes.';
          }
          continue;
        }

        if (fileTime.isAfter(timelineLocations.last.timestamp)) {
          // File is newer than our last timeline point
          final diff = fileTime.difference(timelineLocations.last.timestamp).abs();
          if (diff.inMinutes <= 30) {
            item.location = timelineLocations.last;
            item.isError = false;
            item.errorMessage = null;
          } else {
             item.location = null;
             item.isError = true;
             item.errorMessage = 'No nearest timeline location found within 30 minutes.';
          }
          continue;
        }

        // The fileTime is within the range of our timeline. Find the point right before and right after.
        LocationPoint? prevPoint;
        LocationPoint? nextPoint;

        for (int i = 0; i < timelineLocations.length - 1; i++) {
          if (fileTime.compareTo(timelineLocations[i].timestamp) >= 0 &&
              fileTime.compareTo(timelineLocations[i + 1].timestamp) <= 0) {
            prevPoint = timelineLocations[i];
            nextPoint = timelineLocations[i + 1];
            break;
          }
        }

        if (prevPoint != null && nextPoint != null) {
          // Check if distance between two points is within reasonable timeframe (e.g. less than 2 hours apart)
          // to avoid interpolating over huge gaps
          if (nextPoint.timestamp.difference(prevPoint.timestamp).inMinutes > maxInterpolationGapMinutes) {
             // Too big of a gap, fallback to nearest point logic
             final prevDiff = fileTime.difference(prevPoint.timestamp).abs();
             final nextDiff = nextPoint.timestamp.difference(fileTime).abs();
             LocationPoint closest = prevDiff < nextDiff ? prevPoint : nextPoint;
             Duration minDiff = prevDiff < nextDiff ? prevDiff : nextDiff;

             if (minDiff.inMinutes <= 30) {
                item.location = closest;
                item.isError = false;
                item.errorMessage = null;
             } else {
                item.location = null;
                item.isError = true;
                item.errorMessage = 'Too much time gap between points for interpolation (Gap > $maxInterpolationGapMinutes mins)';
             }
             continue;
          }

          // Interpolate!
          int totalDiffSc = nextPoint.timestamp.difference(prevPoint.timestamp).inSeconds;
          if (totalDiffSc == 0) {
             item.location = prevPoint; // Exact same time
             item.isError = false;
             item.errorMessage = null;
             continue;
          }
          
          int elapsedSc = fileTime.difference(prevPoint.timestamp).inSeconds;
          double ratio = elapsedSc / totalDiffSc; // 0.0 to 1.0

          double interpLat = prevPoint.latitude + (nextPoint.latitude - prevPoint.latitude) * ratio;
          double interpLng = prevPoint.longitude + (nextPoint.longitude - prevPoint.longitude) * ratio;

          item.location = LocationPoint(
            latitude: interpLat,
            longitude: interpLng,
            timestamp: fileTime,
          );
          item.isError = false;
          item.errorMessage = null;
        } else {
          item.location = null;
          item.isError = true;
          item.errorMessage = 'Could not calculate interpolation.';
        }
      } catch (e) {
        item.isError = true;
        item.errorMessage = 'Failed to match location: $e';
      }
    }
    _sortItems();
    notifyListeners();
  }

  Future<void> applyChanges() async {
    isProcessing = true;
    
    // Count how many items need to be processed
    var itemsToProcess = items.where((item) => item.isChecked && item.location != null && !item.isError).toList();
    totalProcessing = itemsToProcess.length;
    currentProcessing = 0;
    
    notifyListeners();

    for (var item in itemsToProcess) {
      if (item.isChecked && item.location != null && !item.isError) {
        try {
          if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
            // native_exif doesn't fully support macOS/desktop writing, so we fallback to exiftool
            final lat = item.location!.latitude.abs();
            final latRef = item.location!.latitude >= 0 ? "N" : "S";
            final lng = item.location!.longitude.abs();
            final lngRef = item.location!.longitude >= 0 ? "E" : "W";
            
            final result = await Process.run('exiftool', [
              '-GPSLatitude=$lat',
              '-GPSLatitudeRef=$latRef',
              '-GPSLongitude=$lng',
              '-GPSLongitudeRef=$lngRef',
              '-overwrite_original',
              item.path
            ]);
            
            if (result.exitCode != 0) {
              throw Exception('ExifTool error: ${result.stderr}');
            }
          } else {
            // Use native_exif for Android/iOS
            final exif = await Exif.fromPath(item.path);
            await exif.writeAttributes({
              'GPSLatitude': item.location!.latitude.abs().toString(),
              'GPSLatitudeRef': item.location!.latitude >= 0 ? 'N' : 'S',
              'GPSLongitude': item.location!.longitude.abs().toString(),
              'GPSLongitudeRef': item.location!.longitude >= 0 ? 'E' : 'W',
            });
            await exif.close();
          }
          
          item.isSuccess = true;
          item.isError = false;
          item.errorMessage = null;
        } catch (e) {
          item.isError = true;
          item.isSuccess = false;
          item.errorMessage = 'Geotagging failed: $e';
        }
      }
      currentProcessing++;
      notifyListeners();
    }

    isProcessing = false;
    notifyListeners();
    
    // Auto clear list on success
    if (autoClearList && !items.any((item) => item.isError)) {
      // Delay to let the user see the visual feedback before it clears
      Future.delayed(const Duration(seconds: 1), () {
         clearFiles();
      });
    }
  }
}
