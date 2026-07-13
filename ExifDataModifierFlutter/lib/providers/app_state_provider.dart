import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import '../models/location_point.dart';
import '../services/location_manager.dart';
import '../utils/geo_utils.dart';

class AppStateProvider extends ChangeNotifier {
  int _currentIndex = 0;

  int get currentIndex => _currentIndex;

  void setIndex(int index) {
    if (_currentIndex != index) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  AppStateProvider() {
    initializeAndScanAppStorage();
  }

  Future<String> getAppTimelinesDirectoryPath({required bool active}) async {
    final docDir = await getApplicationDocumentsDirectory();
    final subDir = active ? 'active' : 'original';
    final dir = Directory(path.join(docDir.path, 'timelines', subDir));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> initializeAndScanAppStorage() async {
    try {
      final activePath = await getAppTimelinesDirectoryPath(active: true);
      final dates = await LocationManager.scanExportedData(activePath);
      _allDates = dates;
      _lastLoadedPath = activePath;
      notifyListeners();
    } catch (e) {
      debugPrint('Error scanning app storage: $e');
    }
  }

  Future<void> saveImportedPoints(List<LocationPoint> points) async {
    if (points.isEmpty) return;

    final Map<String, List<LocationPoint>> pointsByDate = {};
    for (final p in points) {
      final dateKey = DateFormat('yyyy-MM-dd').format(p.timestamp.toUtc());
      pointsByDate.putIfAbsent(dateKey, () => []).add(p);
    }

    final activeDir = await getAppTimelinesDirectoryPath(active: true);
    final originalDir = await getAppTimelinesDirectoryPath(active: false);

    for (final entry in pointsByDate.entries) {
      final dateStr = entry.key;
      final dayPoints = entry.value;
      dayPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final activeFile = File(path.join(activeDir, '$dateStr.json'));
      final originalFile = File(path.join(originalDir, '$dateStr.json'));

      final geojsonMap = LocationPoint.toGeoJson(dayPoints);
      final jsonString = const JsonEncoder.withIndent('  ').convert(geojsonMap);

      await activeFile.writeAsString(jsonString, flush: true);
      await originalFile.writeAsString(jsonString, flush: true);
    }

    await initializeAndScanAppStorage();
  }

  Future<void> restoreDateToOriginal(DateInfo dateInfo) async {
    final activePath = dateInfo.filePath;
    final originalPath = activePath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    );

    final activeFile = File(activePath);
    final originalFile = File(originalPath);

    if (await originalFile.exists()) {
      final content = await originalFile.readAsString();
      await activeFile.writeAsString(content, flush: true);

      // Reload points
      final points = await LocationManager.loadLocationFile(activePath);

      // Update in activePaths if it is currently visible on the map
      if (_activePaths.containsKey(activePath)) {
        _activePaths[activePath] = points;
      }

      // Update in _allDates
      final idx = _allDates.indexWhere((d) => d.filePath == activePath);
      if (idx != -1) {
        _allDates[idx] = DateInfo(
          date: dateInfo.date,
          pointCount: points.length,
          filePath: activePath,
        );
      }
      notifyListeners();
    } else {
      throw Exception('Original backup does not exist for this date.');
    }
  }

  Future<void> deleteDate(DateInfo dateInfo) async {
    final activePath = dateInfo.filePath;
    final originalPath = activePath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    );

    final activeFile = File(activePath);
    final originalFile = File(originalPath);

    if (await activeFile.exists()) {
      await activeFile.delete();
    }
    if (await originalFile.exists()) {
      await originalFile.delete();
    }

    _activePaths.remove(activePath);
    _pathColors.remove(activePath);
    _allDates.removeWhere((d) => d.filePath == activePath);
    notifyListeners();
  }

  // ── Timeline handle state ──────────────────────────────────────────────────
  List<DateInfo> _allDates = [];
  String? _lastLoadedPath;
  final Map<String, List<LocationPoint>> _activePaths = {}; // filePath -> points
  final Map<String, Color> _pathColors = {}; // filePath -> color

  List<DateInfo> get allDates => _allDates;
  String? get lastLoadedPath => _lastLoadedPath;
  Map<String, List<LocationPoint>> get activePaths => _activePaths;
  Map<String, Color> get pathColors => _pathColors;

  final List<Color> _colorPalette = const [
    Color(0xFF7F92FF), // Expressive Periwinkle / Blue
    Color(0xFFFFB4A2), // Expressive Salmon / Coral Red
    Color(0xFF90D9A1), // Expressive Sage / Mint Green
    Color(0xFFFFC08B), // Expressive Peach / Warm Orange
    Color(0xFFDAB6FC), // Expressive Mauve / Lavender
    Color(0xFF7CD3E4), // Expressive Sky / Soft Teal
    Color(0xFFF4D35E), // Expressive Mustard / Soft Yellow
    Color(0xFFF9A8D4), // Expressive Dusty Rose / Pink
    Color(0xFF96B3C2), // Expressive Slate Blue / Steel
    Color(0xFFC3C99C), // Expressive Olive / Soft Khaki
  ];

  void setDatesLoaded(List<DateInfo> newDates, String path) {
    _lastLoadedPath = path;
    final Map<String, DateInfo> merged = {
      for (var d in _allDates) d.filePath: d,
    };

    for (var d in newDates.reversed) {
      merged[d.filePath] = d;
    }

    _allDates = merged.values.toList();
    _allDates.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();
  }

  void togglePathVisibility(DateInfo dateInfo, List<LocationPoint> points) {
    if (_activePaths.containsKey(dateInfo.filePath)) {
      _activePaths.remove(dateInfo.filePath);
      _pathColors.remove(dateInfo.filePath);
    } else {
      _activePaths[dateInfo.filePath] = points;
      _pathColors[dateInfo.filePath] =
          _colorPalette[_activePaths.length % _colorPalette.length];
    }
    notifyListeners();
  }

  // ── Phase 2: Timeline Editing State ────────────────────────────────────────
  String? _editingPathKey;
  List<LocationPoint> _editingPoints = [];
  Set<int> _pinnedPointIndices = {};

  String? get editingPathKey => _editingPathKey;
  List<LocationPoint> get editingPoints => _editingPoints;
  Set<int> get pinnedPointIndices => _pinnedPointIndices;
  bool get isEditing => _editingPathKey != null;

  void startEditing(String pathKey) {
    if (!_activePaths.containsKey(pathKey)) return;
    _editingPathKey = pathKey;
    _editingPoints = List<LocationPoint>.from(_activePaths[pathKey]!);
    
    // Default anchors: always pin the start and end points
    if (_editingPoints.isNotEmpty) {
      _pinnedPointIndices = {0, _editingPoints.length - 1};
    } else {
      _pinnedPointIndices = {};
    }
    notifyListeners();
  }

  void cancelEditing() {
    _editingPathKey = null;
    _editingPoints.clear();
    _pinnedPointIndices.clear();
    notifyListeners();
  }

  void insertPoint(int index, LatLng latLng, double t) {
    if (index < 1 || index > _editingPoints.length) return;

    final tPrev = _editingPoints[index - 1].timestamp;
    final tNext = _editingPoints[index].timestamp;
    final diffMs = tNext.difference(tPrev).inMilliseconds;
    final newTime = tPrev.add(Duration(milliseconds: (diffMs * t).toInt()));

    final newPt = LocationPoint(
      latitude: latLng.latitude,
      longitude: latLng.longitude,
      timestamp: newTime,
      elevation: _editingPoints[index - 1].elevation,
      activityType: _editingPoints[index - 1].activityType,
    );

    _editingPoints.insert(index, newPt);

    // Shift pinned indices that are >= index
    final Set<int> newPinned = {};
    for (final idx in _pinnedPointIndices) {
      if (idx >= index) {
        newPinned.add(idx + 1);
      } else {
        newPinned.add(idx);
      }
    }
    // Auto pin the new point
    newPinned.add(index);
    _pinnedPointIndices = newPinned;

    notifyListeners();
  }

  void togglePin(int index) {
    if (index <= 0 || index >= _editingPoints.length - 1) {
      // Cannot unpin start or end anchors
      return;
    }
    if (_pinnedPointIndices.contains(index)) {
      _pinnedPointIndices.remove(index);
    } else {
      _pinnedPointIndices.add(index);
    }
    notifyListeners();
  }

  void updatePointCoordinate(int index, LatLng newLatLng) {
    if (index < 0 || index >= _editingPoints.length) return;
    final oldPt = _editingPoints[index];
    _editingPoints[index] = LocationPoint(
      latitude: newLatLng.latitude,
      longitude: newLatLng.longitude,
      timestamp: oldPt.timestamp,
      elevation: oldPt.elevation,
      activityType: oldPt.activityType,
    );
    notifyListeners();
  }

  void updatePointTimeAndInterpolate(int index, DateTime newTime) {
    if (index < 0 || index >= _editingPoints.length) return;

    // Pin this index
    _pinnedPointIndices.add(index);

    // Find previous control point 'a'
    int a = 0;
    for (int i = index - 1; i >= 0; i--) {
      if (_pinnedPointIndices.contains(i)) {
        a = i;
        break;
      }
    }

    // Find next control point 'b'
    int b = _editingPoints.length - 1;
    for (int i = index + 1; i < _editingPoints.length; i++) {
      if (_pinnedPointIndices.contains(i)) {
        b = i;
        break;
      }
    }

    final timeA = _editingPoints[a].timestamp;
    final timeB = _editingPoints[b].timestamp;

    // Safety clamp: newTime must be strictly between timeA and timeB
    if (newTime.isBefore(timeA) || newTime.isAfter(timeB)) {
      if (newTime.isBefore(timeA)) {
        newTime = timeA.add(const Duration(seconds: 1));
      } else {
        newTime = timeB.subtract(const Duration(seconds: 1));
      }
    }

    // Update index point
    final oldIdx = _editingPoints[index];
    _editingPoints[index] = LocationPoint(
      latitude: oldIdx.latitude,
      longitude: oldIdx.longitude,
      timestamp: newTime,
      elevation: oldIdx.elevation,
      activityType: oldIdx.activityType,
    );

    // 1. Interpolate segment A -> Index
    _interpolateRange(a, index);

    // 2. Interpolate segment Index -> B
    _interpolateRange(index, b);

    notifyListeners();
  }

  void _interpolateRange(int start, int end) {
    if (end - start <= 1) return;

    final pStart = _editingPoints[start];
    final pEnd = _editingPoints[end];
    final timeStart = pStart.timestamp;
    final timeEnd = pEnd.timestamp;
    final totalDuration = timeEnd.difference(timeStart);

    // Compute cumulative distances
    final List<double> distances = [0.0];
    double totalDist = 0.0;
    for (int i = start; i < end; i++) {
      final d = GeoUtils.distanceBetween(_editingPoints[i].latLng, _editingPoints[i + 1].latLng);
      totalDist += d;
      distances.add(totalDist);
    }

    for (int i = start + 1; i < end; i++) {
      final oldPt = _editingPoints[i];
      final double progress = totalDist > 0
          ? distances[i - start] / totalDist
          : (i - start) / (end - start);
      
      final int offsetMs = (totalDuration.inMilliseconds * progress).toInt();
      final newTime = timeStart.add(Duration(milliseconds: offsetMs));

      _editingPoints[i] = LocationPoint(
        latitude: oldPt.latitude,
        longitude: oldPt.longitude,
        timestamp: newTime,
        elevation: oldPt.elevation,
        activityType: oldPt.activityType,
      );
    }
  }

  Future<void> saveEditingChanges(double? timezoneOffset) async {
    if (_editingPathKey == null) return;
    
    // 1. Update the local memory state
    _editingPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _activePaths[_editingPathKey!] = List<LocationPoint>.from(_editingPoints);
    
    // 2. Write to the file
    final file = File(_editingPathKey!);
    final geojsonMap = LocationPoint.toGeoJson(_editingPoints, timezoneOffset);
    final jsonString = const JsonEncoder.withIndent('  ').convert(geojsonMap);
    await file.writeAsString(jsonString);
    
    // 3. Update the date list info
    final savedKey = _editingPathKey;
    final dateIdx = _allDates.indexWhere((d) => d.filePath == savedKey);
    if (dateIdx != -1) {
      final oldDate = _allDates[dateIdx];
      _allDates[dateIdx] = DateInfo(
        date: oldDate.date,
        pointCount: _editingPoints.length,
        filePath: oldDate.filePath,
      );
    }

    // 4. Clear editing state
    _editingPathKey = null;
    _editingPoints.clear();
    _pinnedPointIndices.clear();
    
    notifyListeners();
  }
}
