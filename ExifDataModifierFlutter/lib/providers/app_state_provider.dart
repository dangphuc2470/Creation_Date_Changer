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
import '../services/batch_import_service.dart';

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

  Future<void> saveBatchGroups(List<FileGroup> groups) async {
    final activeDir = await getAppTimelinesDirectoryPath(active: true);
    final originalDir = await getAppTimelinesDirectoryPath(active: false);

    for (final group in groups) {
      final dateStr = group.date; // already YYYY-MM-DD
      List<LocationPoint> timelinePts = [];
      List<LocationPoint> gpxPts = [];

      for (final file in group.files) {
        if (file.isSelected) {
          final isGpx = file.filePath.toLowerCase().endsWith('.gpx');
          final filePoints = file.points.where((p) => DateFormat('yyyy-MM-dd').format(p.timestamp.toUtc()) == dateStr).toList();
          if (isGpx) {
            gpxPts.addAll(filePoints);
          } else {
            timelinePts.addAll(filePoints);
          }
        }
      }

      if (timelinePts.isEmpty && gpxPts.isEmpty) continue;

      // Save backups
      if (timelinePts.isNotEmpty) {
        final f = File(path.join(originalDir, '${dateStr}_timeline.json'));
        await f.writeAsString(const JsonEncoder.withIndent('  ').convert(
          LocationPoint.toGeoJson(timelinePts, null, 'original', 'timeline')
        ), flush: true);
      }
      if (gpxPts.isNotEmpty) {
        final f = File(path.join(originalDir, '${dateStr}_gpx.json'));
        await f.writeAsString(const JsonEncoder.withIndent('  ').convert(
          LocationPoint.toGeoJson(gpxPts, null, 'original', 'gpx')
        ), flush: true);
      }

      // Merge and save active
      List<LocationPoint> activePoints = [];
      String activeSource = 'merge';
      if (timelinePts.isNotEmpty && gpxPts.isNotEmpty) {
        activePoints = mergeTimelineAndGpx(timelinePts, gpxPts);
      } else if (gpxPts.isNotEmpty) {
        activeSource = 'gpx';
        activePoints = gpxPts;
      } else {
        activeSource = 'timeline';
        activePoints = timelinePts;
      }

      final activeFile = File(path.join(activeDir, '$dateStr.json'));
      await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(
        LocationPoint.toGeoJson(activePoints, null, 'original', activeSource)
      ), flush: true);
    }

    await initializeAndScanAppStorage();
  }

  Future<void> saveImportedPoints(List<LocationPoint> points, String importSource) async {
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

      // 1. Save original copy for this specific source: e.g. YYYY-MM-DD_gpx.json or YYYY-MM-DD_timeline.json
      final specificOriginalFile = File(path.join(originalDir, '${dateStr}_$importSource.json'));
      final geojsonSpecific = LocationPoint.toGeoJson(dayPoints, null, 'original', importSource);
      await specificOriginalFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonSpecific), flush: true);

      // 2. Check if the other backup file exists to merge, or just use this one
      final otherSource = importSource == 'gpx' ? 'timeline' : 'gpx';
      final otherOriginalFile = File(path.join(originalDir, '${dateStr}_$otherSource.json'));
      
      List<LocationPoint> activePoints = [];
      String activeSource = importSource;

      if (await otherOriginalFile.exists()) {
        activeSource = 'merge';
        final otherContent = await otherOriginalFile.readAsString();
        final otherPoints = LocationPoint.parseAnyJson(jsonDecode(otherContent));
        
        final timelinePts = importSource == 'timeline' ? dayPoints : otherPoints;
        final gpxPts = importSource == 'gpx' ? dayPoints : otherPoints;
        activePoints = mergeTimelineAndGpx(timelinePts, gpxPts);
      } else {
        activePoints = dayPoints;
      }

      // 3. Save to active YYYY-MM-DD.json
      final activeFile = File(path.join(activeDir, '$dateStr.json'));
      final geojsonActive = LocationPoint.toGeoJson(activePoints, null, 'original', activeSource);
      await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonActive), flush: true);
    }

    await initializeAndScanAppStorage();
  }

  List<LocationPoint> mergeTimelineAndGpx(List<LocationPoint> timeline, List<LocationPoint> gpx) {
    if (gpx.isEmpty) return timeline;
    if (timeline.isEmpty) return gpx;

    final gpxStart = gpx.first.timestamp;
    final gpxEnd = gpx.last.timestamp;

    // Filter out timeline points in GPX range
    final filteredTimeline = timeline.where((p) => p.timestamp.isBefore(gpxStart) || p.timestamp.isAfter(gpxEnd)).toList();

    final merged = [...filteredTimeline, ...gpx];
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return merged;
  }

  Future<void> updateDaySource(DateInfo dateInfo, String newSource) async {
    final activePath = dateInfo.filePath;
    final dateStr = DateFormat('yyyy-MM-dd').format(dateInfo.date);
    final originalDir = await getAppTimelinesDirectoryPath(active: false);

    final timelineFile = File(path.join(originalDir, '${dateStr}_timeline.json'));
    final gpxFile = File(path.join(originalDir, '${dateStr}_gpx.json'));

    List<LocationPoint> finalPoints = [];

    if (newSource == 'timeline') {
      if (await timelineFile.exists()) {
        finalPoints = LocationPoint.parseAnyJson(jsonDecode(await timelineFile.readAsString()));
      }
    } else if (newSource == 'gpx') {
      if (await gpxFile.exists()) {
        finalPoints = LocationPoint.parseAnyJson(jsonDecode(await gpxFile.readAsString()));
      }
    } else {
      // merge
      List<LocationPoint> timelinePts = [];
      List<LocationPoint> gpxPts = [];
      if (await timelineFile.exists()) {
        timelinePts = LocationPoint.parseAnyJson(jsonDecode(await timelineFile.readAsString()));
      }
      if (await gpxFile.exists()) {
        gpxPts = LocationPoint.parseAnyJson(jsonDecode(await gpxFile.readAsString()));
      }
      finalPoints = mergeTimelineAndGpx(timelinePts, gpxPts);
    }

    // Save to active with current day state
    final activeFile = File(activePath);
    final geojsonMap = LocationPoint.toGeoJson(finalPoints, null, dateInfo.state, newSource);
    await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonMap), flush: true);

    await initializeAndScanAppStorage();
  }

  Future<void> snapToRoads(DateInfo dateInfo) async {
    final activePath = dateInfo.filePath;
    final activeFile = File(activePath);
    if (await activeFile.exists()) {
      final points = await LocationManager.loadLocationFile(activePath);

      // Save with state: 'snapped'
      final geojsonMap = LocationPoint.toGeoJson(points, null, 'snapped', dateInfo.source);
      await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonMap), flush: true);

      await initializeAndScanAppStorage();
    }
  }

  Future<void> saveListPoints(DateInfo dateInfo, List<LocationPoint> points) async {
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final activeFile = File(dateInfo.filePath);
    
    // Save to active with state: 'edited'
    final geojsonMap = LocationPoint.toGeoJson(points, null, 'edited', dateInfo.source);
    await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonMap), flush: true);

    LocationManager.updateCache(dateInfo.filePath, points);

    await initializeAndScanAppStorage();
  }

  Future<void> restoreDateToOriginal(DateInfo dateInfo) async {
    final activePath = dateInfo.filePath;
    final originalPath = activePath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    );

    final activeFile = File(activePath);
    final File originalFileBackup = File(originalPath);
    File? sourceToRestore;
    if (await originalFileBackup.exists()) {
      sourceToRestore = originalFileBackup;
    } else {
      final dateStr = DateFormat('yyyy-MM-dd').format(dateInfo.date);
      final timelineBackup = File(path.join(originalFileBackup.parent.path, '${dateStr}_timeline.json'));
      final gpxBackup = File(path.join(originalFileBackup.parent.path, '${dateStr}_gpx.json'));
      if (await timelineBackup.exists()) {
        sourceToRestore = timelineBackup;
      } else if (await gpxBackup.exists()) {
        sourceToRestore = gpxBackup;
      }
    }

    if (sourceToRestore != null) {
      final content = await sourceToRestore.readAsString();
      final decoded = jsonDecode(content);
      final points = LocationPoint.parseAnyJson(decoded);
      String originalSource = dateInfo.source;
      if (decoded is Map<String, dynamic>) {
        final properties = decoded['properties'] as Map<String, dynamic>? ?? {};
        originalSource = properties['source'] as String? ?? dateInfo.source;
      }

      final geojsonMap = LocationPoint.toGeoJson(points, null, 'original', originalSource);
      await activeFile.writeAsString(const JsonEncoder.withIndent('  ').convert(geojsonMap), flush: true);

      // Invalidate the cache to reload restored file data
      LocationManager.invalidateCache(activePath);
      // Reload points
      final reloadedPoints = await LocationManager.loadLocationFile(activePath);

      // Update in activePaths if it is currently visible on the map
      if (_activePaths.containsKey(activePath)) {
        _activePaths[activePath] = reloadedPoints;
      }

      await initializeAndScanAppStorage();
    } else {
      throw Exception('Original backup does not exist for this date.');
    }
  }

  Future<void> deleteDate(DateInfo dateInfo) async {
    final activePath = dateInfo.filePath;
    final dateStr = DateFormat('yyyy-MM-dd').format(dateInfo.date);
    
    final activeFile = File(activePath);
    final originalFile = File(activePath.replaceAll(
      path.join('timelines', 'active'),
      path.join('timelines', 'original'),
    ));
    final originalTimelineFile = File(path.join(originalFile.parent.path, '${dateStr}_timeline.json'));
    final originalGpxFile = File(path.join(originalFile.parent.path, '${dateStr}_gpx.json'));

    if (await activeFile.exists()) {
      await activeFile.delete();
    }
    if (await originalFile.exists()) {
      await originalFile.delete();
    }
    if (await originalTimelineFile.exists()) {
      await originalTimelineFile.delete();
    }
    if (await originalGpxFile.exists()) {
      await originalGpxFile.delete();
    }

    _activePaths.remove(activePath);
    _pathColors.remove(activePath);
    _allDates.removeWhere((d) => d.filePath == activePath);
    await initializeAndScanAppStorage();
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

  void setSelectedDatePath(DateInfo dateInfo, List<LocationPoint> points) {
    _activePaths.clear();
    _pathColors.clear();
    if (dateInfo.filePath.isNotEmpty && points.isNotEmpty) {
      _activePaths[dateInfo.filePath] = points;
      _pathColors[dateInfo.filePath] = const Color(0xFF7F92FF);
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

  void setEditingPoints(List<LocationPoint> points) {
    _editingPoints = List<LocationPoint>.from(points);
    notifyListeners();
  }

  void setPinnedPointIndices(Set<int> indices) {
    _pinnedPointIndices = Set<int>.from(indices);
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
    
    // Get existing source
    final savedKey = _editingPathKey;
    final dateIdx = _allDates.indexWhere((d) => d.filePath == savedKey);
    String source = 'merge';
    if (dateIdx != -1) {
      source = _allDates[dateIdx].source;
    }

    // 2. Write to the file (marking state as edited)
    final file = File(_editingPathKey!);
    final geojsonMap = LocationPoint.toGeoJson(_editingPoints, timezoneOffset, 'edited', source);
    final jsonString = const JsonEncoder.withIndent('  ').convert(geojsonMap);
    await file.writeAsString(jsonString, flush: true);
    
    // 3. Scan storage to update metadata
    await initializeAndScanAppStorage();

    // 4. Clear editing state
    _editingPathKey = null;
    _editingPoints.clear();
    _pinnedPointIndices.clear();
    
    notifyListeners();
  }
}
