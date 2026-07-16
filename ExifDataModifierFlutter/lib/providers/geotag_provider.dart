import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/location_point.dart';
import 'package:native_exif/native_exif.dart';

class GeotagItem {
  final File file;
  final String path;
  final String filename;
  LocationPoint? location;
  bool isError;
  bool isSuccess;
  String? errorMessage;
  bool hasExistingGps;
  bool isChecked;
  bool isManualLocation;

  /// Cached DateTimeOriginal from EXIF (null = not read yet or not present)
  DateTime? dateTaken;

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
    this.dateTaken,
  });
}

class TaggedHistoryItem {
  final String path;
  final double latitude;
  final double longitude;
  final bool isManual;

  TaggedHistoryItem({
    required this.path,
    required this.latitude,
    required this.longitude,
    this.isManual = false,
  });
}

class GeotagProvider extends ChangeNotifier {
  List<GeotagItem> items = [];
  List<TaggedHistoryItem> historyMarkers = [];
  List<LocationPoint> timelineLocations = [];

  // ── Apply-geotags progress ──────────────────────────────────────────────────
  bool isProcessing = false;
  int currentProcessing = 0;
  int totalProcessing = 0;

  // ── Loading-files progress ──────────────────────────────────────────────────
  /// True while addFiles() is scanning for GPS + reading EXIF
  bool isLoadingFiles = false;
  int loadedFilesCount = 0;
  int totalFilesToLoad = 0;

  // ── Match-location progress ─────────────────────────────────────────────────
  /// True while matchLocations() is running
  bool isMatching = false;
  int matchedCount = 0;
  int totalToMatch = 0;

  /// Human-readable description of whatever is currently happening
  String loadingMessage = '';

  /// The location of the last successfully matched item (set after match completes)
  LocationPoint? lastMatchedLocation;

  /// True once the user has run at least one match (so settings changes re-match)
  bool _hasMatchedOnce = false;

  // ── Cancellation flags ──────────────────────────────────────────────────────
  bool _cancelLoad = false;
  bool _cancelMatch = false;

  void cancelLoad() {
    _cancelLoad = true;
  }

  void cancelMatch() {
    _cancelMatch = true;
  }

  // ── Settings ────────────────────────────────────────────────────────────────
  Duration timeOffset = Duration.zero;
  bool overrideExistingGps = false;
  bool autoClearList = false;
  int maxInterpolationGapMinutes = 120;
  bool showImagePreviews = true;
  String? loadedTimelineFileName;
  LocationPoint? lastPinnedLocation;
  int geotagTimezone = 7;

  GeotagProvider() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    geotagTimezone = prefs.getInt('geotagTimezone') ?? 7;
    timeOffset = Duration(hours: -geotagTimezone);
    await loadTimelineLocationsFromAppDb();
  }

  Future<void> loadTimelineLocationsFromAppDb() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final activeDir = Directory(p.join(docDir.path, 'timelines', 'active'));
      if (!await activeDir.exists()) {
        timelineLocations = [];
        loadedTimelineFileName = null;
        notifyListeners();
        return;
      }

      final List<LocationPoint> allPoints = [];
      final files = await activeDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();

      for (final file in files) {
        try {
          final content = await file.readAsString();
          final decoded = jsonDecode(content);
          final points = LocationPoint.parseAnyJson(decoded);
          allPoints.addAll(points);
        } catch (_) {}
      }

      allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      timelineLocations = allPoints;
      loadedTimelineFileName = files.isNotEmpty ? 'App Database (${files.length} days)' : null;
      notifyListeners();
    } catch (e) {
      timelineLocations = [];
      loadedTimelineFileName = 'App Database Error';
      notifyListeners();
    }
  }

  void setShowImagePreviews(bool value) {
    showImagePreviews = value;
    notifyListeners();
  }

  Future<String> _getExifToolExecutable() async {
    try {
      final result = await Process.run('exiftool', ['-ver']);
      if (result.exitCode == 0) return 'exiftool';
    } catch (_) {}

    if (Platform.isWindows) {
      final cPath = 'C:\\exiftool\\exiftool.exe';
      if (await File(cPath).exists()) return cPath;
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(p.join(appDir.path, 'exiftool.exe'));
      if (!(await exeFile.exists())) {
        final data = await rootBundle.load('assets/bin/exiftool.exe');
        final bytes = data.buffer.asUint8List();
        await exeFile.writeAsBytes(bytes);
      }
      return exeFile.path;
    } catch (e) {
      return 'exiftool';
    }
  }

  void clearHistory() {
    historyMarkers.clear();
    notifyListeners();
  }

  void setMaxInterpolationGapMinutes(int val) {
    maxInterpolationGapMinutes = val;
    if (_hasMatchedOnce) matchLocations();
  }

  void setOverrideExistingGps(bool value) {
    overrideExistingGps = value;
    if (_hasMatchedOnce) matchLocations();
    notifyListeners();
  }

  void setAutoClearList(bool value) {
    autoClearList = value;
    notifyListeners();
  }

  void setTimezone(int tz) async {
    geotagTimezone = tz;
    timeOffset = Duration(hours: -tz); // Offset to get to UTC
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('geotagTimezone', tz);
    if (_hasMatchedOnce) matchLocations();
    notifyListeners();
  }

  void toggleItemCheck(GeotagItem item, bool value) {
    item.isChecked = value;
    notifyListeners();
  }

  void checkAll() {
    for (var item in items) {
      item.isChecked = true;
    }
    notifyListeners();
  }

  void uncheckAll() {
    for (var item in items) {
      item.isChecked = false;
    }
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

  // ── addFiles ────────────────────────────────────────────────────────────────
  /// Adds files to the list, reading GPS-presence + DateTimeOriginal in a single
  /// ExifTool batch call on desktop (two tags, one process). Cancellable via
  /// [cancelLoad]. Does NOT run matchLocations — user presses the button.
  Future<void> addFiles(List<File> files) async {
    final newFiles =
        files.where((f) => !items.any((i) => i.path == f.path)).toList();
    if (newFiles.isEmpty) return;

    _cancelLoad = false;
    isLoadingFiles = true;
    totalFilesToLoad = newFiles.length;
    loadedFilesCount = 0;
    loadingMessage = 'Preparing…';
    notifyListeners();

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      // ── Desktop: ONE ExifTool call reads GPS + DateTimeOriginal for ALL files
      await _batchReadExifDesktop(newFiles);
    } else {
      // ── Mobile: native_exif per-file (unavoidable), with cancel support
      await _perFileReadExifMobile(newFiles);
    }

    if (!_cancelLoad) {
      _sortItems();
    }
    isLoadingFiles = false;
    _cancelLoad = false;
    loadingMessage = '';
    notifyListeners();
  }

  /// Desktop fast path: reads GPSLatitude + DateTimeOriginal for every file
  /// in a single ExifTool invocation using CSV output.
  Future<void> _batchReadExifDesktop(List<File> newFiles) async {
    // First add all items immediately so the list appears populated
    for (final file in newFiles) {
      items.add(GeotagItem(
        file: file,
        path: file.path,
        filename: file.uri.pathSegments.last,
        isError: true,
        errorMessage: 'Reading EXIF…',
      ));
    }
    loadingMessage = 'Reading EXIF for ${newFiles.length} files…';
    notifyListeners();

    try {
      final exe = await _getExifToolExecutable();
      if (_cancelLoad) return;

      // Dynamic Batching: Group files based on total path length to maximize performance
      // while staying under Windows' 8191 character limit.
      final batches = _getDynamicChunks<File>(newFiles, (f) => f.path,
          100 // Reserved for: exiftool -GPSLatitude -DateTimeOriginal -d ... -csv
          );

      for (final chunk in batches) {
        if (_cancelLoad) break;

        final result = await Process.run(exe, [
          '-GPSLatitude',
          '-DateTimeOriginal',
          '-d',
          '%Y-%m-%dT%H:%M:%S',
          '-f', // print "-" when tag absent so row count stays stable
          '-csv',
          ...chunk.map((f) => f.path),
        ]);

        if (result.exitCode != 0) {
          loadingMessage =
              'Batch error. Tip: Try moving files to a shorter folder path (e.g. C:\\Photos).';
          notifyListeners();
          continue;
        }

        // CSV format: SourceFile,GPSLatitude,DateTimeOriginal
        final lines = result.stdout.toString().split('\n');
        if (lines.isEmpty) continue;

        // Header is on line 0 of EACH batch call because of -csv
        final headers = _parseCsvLine(lines[0]);
        final gpsIdx = headers.indexOf('GPSLatitude');
        final dateIdx = headers.indexOf('DateTimeOriginal');
        final fileIdx = headers.indexOf('SourceFile');

        for (int j = 1; j < lines.length; j++) {
          final line = lines[j].trim();
          if (line.isEmpty) continue;
          final cols = _parseCsvLine(line);
          if (cols.length <= fileIdx) continue;

          final filePath = cols[fileIdx];
          final gpsVal =
              gpsIdx >= 0 && gpsIdx < cols.length ? cols[gpsIdx] : '-';
          final dateVal =
              dateIdx >= 0 && dateIdx < cols.length ? cols[dateIdx] : '-';

          // Find the matching GeotagItem
          GeotagItem? item;
          try {
            item = items.firstWhere(
              (it) => p.equals(it.path, filePath),
            );
          } catch (_) {
            try {
              item = items.firstWhere(
                (it) => it.filename == p.basename(filePath),
              );
            } catch (_) {}
          }

          if (item != null) {
            item.hasExistingGps = gpsVal != '-' && gpsVal.isNotEmpty;
            if (dateVal != '-' && dateVal.isNotEmpty) {
              item.dateTaken = DateTime.tryParse(dateVal);
            }
            item.errorMessage = 'Pending — press Match Location';
            item.isError = false; // Reset error state on success
            loadedFilesCount++;
          }
        }

        loadingMessage = 'Read EXIF $loadedFilesCount / $totalFilesToLoad…';
        notifyListeners();
      }
    } catch (e) {
      // ExifTool failed — mark all new items so user knows
      for (final item
          in items.where((i) => i.errorMessage == 'Reading EXIF…')) {
        item.errorMessage = 'Pending — press Match Location';
      }
    }
  }

  /// Splits a single CSV line respecting quoted fields.
  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuote = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuote = !inQuote;
      } else if (ch == ',' && !inQuote) {
        result.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString().trim());
    return result;
  }

  /// Mobile slow path: native_exif per-file with cancel support.
  Future<void> _perFileReadExifMobile(List<File> newFiles) async {
    for (final file in newFiles) {
      if (_cancelLoad) break;

      bool hasGps = false;
      DateTime? dateTaken;
      try {
        final exif = await Exif.fromPath(file.path);
        final attr = await exif.getAttributes();
        await exif.close();
        if (attr != null &&
            (attr.containsKey('GPSLatitude') ||
                attr.containsKey('GPSLongitude'))) {
          hasGps = true;
        }
        final raw = attr?['DateTimeOriginal'] as String?;
        if (raw != null && raw.isNotEmpty) {
          final normalized = raw.replaceFirstMapped(
            RegExp(r'^(\d{4}):(\d{2}):(\d{2})'),
            (m) => '${m[1]}-${m[2]}-${m[3]}',
          );
          dateTaken = DateTime.tryParse(normalized);
        }
      } catch (_) {}

      items.add(GeotagItem(
        file: file,
        path: file.path,
        filename: file.uri.pathSegments.last,
        hasExistingGps: hasGps,
        dateTaken: dateTaken,
        isError: true,
        errorMessage: 'Pending — press Match Location',
      ));

      loadedFilesCount++;
      loadingMessage = 'Reading file $loadedFilesCount / $totalFilesToLoad…';
      notifyListeners();
    }
  }

  void removeFile(GeotagItem item) {
    items.remove(item);
    notifyListeners();
  }

  void clearFiles() {
    items.clear();
    lastPinnedLocation = null;
    _hasMatchedOnce = false;
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

  /// Load Timeline JSON — does NOT auto-match. Notifies UI so it can prompt user.
  Future<void> loadTimelineData(String jsonData, String filename) async {
    try {
      // Auto-detect timezone from content before parsing
      final detectedTz = _detectTimezoneInContent(jsonData);
      if (detectedTz != null) {
        geotagTimezone = detectedTz;
        timeOffset = Duration(hours: -detectedTz);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('geotagTimezone', detectedTz);
      }

      final decoded = jsonDecode(jsonData);
      timelineLocations = LocationPoint.parseAnyJson(decoded);
      timelineLocations.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      loadedTimelineFileName = filename;
      // Mark pending items so the user knows to re-match
      for (var item in items) {
        if (!item.isManualLocation && !item.isSuccess) {
          item.isError = true;
          item.errorMessage = 'Timeline loaded — press Match Location';
        }
      }
      notifyListeners();
    } catch (e) {
      loadedTimelineFileName = null;
      notifyListeners();
    }
  }

  /// Unload the current timeline — clears all timeline data and resets matched locations.
  void unloadTimeline() {
    timelineLocations.clear();
    loadedTimelineFileName = null;
    lastMatchedLocation = null;
    _hasMatchedOnce = false;
    // Reset non-manual items back to unmatched state
    for (var item in items) {
      if (!item.isManualLocation) {
        item.location = null;
        item.isError = false;
        item.errorMessage = null;
        item.isSuccess = false;
      }
    }
    notifyListeners();
  }

  String _escapeCsv(String text) {
    if (text.contains('"')) {
      return text.replaceAll('"', '""');
    }
    return text;
  }

  /// Groups items into batches based on dynamic command line length calculation.
  /// This prevents Windows 8191 character limit issues while maximizing batch performance.
  List<List<T>> _getDynamicChunks<T>(
      List<T> items, String Function(T) getPath, int reservedLength) {
    const int maxWinCmdLength = 8000; // Leave safety margin from 8191 chars
    List<List<T>> chunks = [];
    List<T> currentChunk = [];
    int currentLength = reservedLength;

    for (var item in items) {
      final path = getPath(item);
      // Path length + 3 for quotes and space
      final pathLength = path.length + 3;

      if (currentLength + pathLength > maxWinCmdLength &&
          currentChunk.isNotEmpty) {
        chunks.add(currentChunk);
        currentChunk = [];
        currentLength = reservedLength;
      }

      currentChunk.add(item);
      currentLength += pathLength;
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }
    return chunks;
  }

  int? _detectTimezoneInContent(String content) {
    try {
      // Look for the first occurrence of a time string with offset
      // Matches +07:00, -05:00 or Z
      final regex = RegExp(r'"time"\s*:\s*"[^"]*?([+-]\d{2}):\d{2}|Z"');
      final match = regex.firstMatch(content);
      if (match == null) return null;

      final offsetPart = match.group(1);
      if (offsetPart == null) {
        // Check if it's 'Z'
        if (match.group(0)!.contains('Z')) return 0;
        return null;
      }

      return int.tryParse(offsetPart);
    } catch (_) {
      return null;
    }
  }

  /// Returns a list of continuous time segments in the timeline,
  /// where each segment is separated by a gap > maxInterpolationGapMinutes.
  List<Map<String, dynamic>> getTimelineSegments() {
    if (timelineLocations.isEmpty) return [];

    List<Map<String, dynamic>> segments = [];
    List<LocationPoint> currentPoints = [timelineLocations.first];
    DateTime segmentStart = timelineLocations.first.timestamp;
    DateTime lastTs = segmentStart;

    for (int i = 1; i < timelineLocations.length; i++) {
      final point = timelineLocations[i];
      final currentTs = point.timestamp;
      // If gap exceeds threshold, end current segment and start new one
      if (currentTs.difference(lastTs).inMinutes > maxInterpolationGapMinutes) {
        segments.add({
          'start': segmentStart,
          'end': lastTs,
          'points': List<LocationPoint>.from(currentPoints),
        });
        segmentStart = currentTs;
        currentPoints.clear();
      }
      currentPoints.add(point);
      lastTs = currentTs;
    }
    segments.add({
      'start': segmentStart,
      'end': lastTs,
      'points': List<LocationPoint>.from(currentPoints),
    });
    return segments;
  }

  void setTimeOffset(Duration offset) {
    timeOffset = offset;
    if (_hasMatchedOnce) matchLocations();
  }

  // ── matchLocations (public, called by button) ────────────────────────────
  Future<void> matchLocations() async {
    if (items.isEmpty) return;

    _cancelMatch = false;
    isMatching = true;
    _hasMatchedOnce = true;
    totalToMatch = items.length;
    matchedCount = 0;
    loadingMessage = 'Matching locations…';
    notifyListeners();

    await _runMatchLocations();

    // Find the last successfully matched location to navigate the map there
    final matched = items
        .where((i) => !i.isError && i.location != null && !i.isManualLocation)
        .toList();
    if (matched.isNotEmpty) {
      lastMatchedLocation = matched.last.location;
    }

    isMatching = false;
    if (_cancelMatch) {
      loadingMessage = 'Matching cancelled.';
    } else {
      loadingMessage = '';
    }
    _cancelMatch = false;
    notifyListeners();
  }

  Future<void> _runMatchLocations() async {
    for (var item in items) {
      if (_cancelMatch) break;

      matchedCount++;
      // Yield to the event loop every 10 items so UI stays responsive
      if (matchedCount % 10 == 0 || matchedCount == totalToMatch) {
        loadingMessage = 'Matching $matchedCount / $totalToMatch…';
        notifyListeners();
        await Future.delayed(Duration.zero);
      }

      if (!overrideExistingGps && item.hasExistingGps) {
        item.isError = false;
        item.errorMessage = 'Has existing GPS (Not overridden)';
        item.location = null;
        continue;
      }

      if (item.isManualLocation) continue;

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
            item.errorMessage = 'No timeline or map pin — cannot match';
          }
        }
        continue;
      }

      try {
        // TREAT PHOTO TIME AS NAIVE (Ignore system local timezone)
        // Convert the "wall time" of the photo to UTC based on our selected timezone.
        final DateTime fileTime;
        final DateTime baseTime =
            item.dateTaken ?? (await item.file.stat()).modified;

        fileTime = DateTime.utc(
          baseTime.year,
          baseTime.month,
          baseTime.day,
          baseTime.hour,
          baseTime.minute,
          baseTime.second,
          baseTime.millisecond,
        ).subtract(Duration(hours: geotagTimezone));

        if (fileTime.isBefore(timelineLocations.first.timestamp)) {
          final diff =
              timelineLocations.first.timestamp.difference(fileTime).abs();
          if (diff.inMinutes <= 30) {
            item.location = timelineLocations.first;
            item.isError = false;
            item.errorMessage = null;
          } else {
            item.location = null;
            item.isError = true;
            item.errorMessage =
                'No nearest timeline location found within 30 minutes.';
          }
          continue;
        }

        if (fileTime.isAfter(timelineLocations.last.timestamp)) {
          final diff =
              fileTime.difference(timelineLocations.last.timestamp).abs();
          if (diff.inMinutes <= 30) {
            item.location = timelineLocations.last;
            item.isError = false;
            item.errorMessage = null;
          } else {
            item.location = null;
            item.isError = true;
            item.errorMessage =
                'No nearest timeline location found within 30 minutes.';
          }
          continue;
        }

        // ── Binary search for the surrounding interval ──────────────────
        // timelineLocations is sorted by timestamp, so binary search on the
        // timestamp of fileTime gives us O(log n) instead of O(n).
        final idx = _binarySearchTimeline(fileTime);
        if (idx >= 0 && idx < timelineLocations.length - 1) {
          final prevPoint = timelineLocations[idx];
          final nextPoint = timelineLocations[idx + 1];

          final gapDuration =
              nextPoint.timestamp.difference(prevPoint.timestamp);
          final gapMins = gapDuration.inMinutes;

          if (gapMins > maxInterpolationGapMinutes) {
            final prevDiff = fileTime.difference(prevPoint.timestamp).abs();
            final nextDiff = nextPoint.timestamp.difference(fileTime).abs();
            final closest = prevDiff < nextDiff ? prevPoint : nextPoint;
            final minDiff = prevDiff < nextDiff ? prevDiff : nextDiff;

            if (minDiff.inMinutes <= 30) {
              item.location = closest;
              item.isError = false;
              item.errorMessage = null;
            } else {
              item.location = null;
              item.isError = true;
              item.errorMessage =
                  'Time gap too big ($gapMins mins) between points.';
            }
          } else {
            final int totalDiffSc = gapDuration.inSeconds;
            if (totalDiffSc <= 0) {
              item.location = prevPoint;
              item.isError = false;
              item.errorMessage = null;
            } else {
              final int elapsedSc =
                  fileTime.difference(prevPoint.timestamp).inSeconds;
              final double ratio = elapsedSc / totalDiffSc;
              item.location = LocationPoint(
                latitude: prevPoint.latitude +
                    (nextPoint.latitude - prevPoint.latitude) * ratio,
                longitude: prevPoint.longitude +
                    (nextPoint.longitude - prevPoint.longitude) * ratio,
                timestamp: fileTime,
              );
              item.isError = false;
              item.errorMessage = null;
            }
          }
        } else {
          item.location = null;
          item.isError = true;
          item.errorMessage = 'No matching timeline interval found.';
        }
      } catch (e) {
        item.isError = true;
        item.errorMessage = 'Match error: $e';
        notifyListeners();
      }
    }
    _sortItems();
  }

  /// Binary search on [timelineLocations] (sorted by timestamp).
  /// Returns the index i such that timelineLocations[i].timestamp <= target
  /// and timelineLocations[i+1].timestamp >= target.
  /// Returns -1 if no such index exists.
  int _binarySearchTimeline(DateTime target) {
    int lo = 0;
    int hi = timelineLocations.length - 2; // we need i+1 to exist
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final ts = timelineLocations[mid].timestamp;
      if (ts == target) return mid;
      if (ts.isBefore(target)) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // hi is now the largest index whose timestamp <= target
    return hi;
  }

  // ── applyChanges ─────────────────────────────────────────────────────────
  Future<void> applyChanges() async {
    isProcessing = true;

    final itemsToProcess = items
        .where(
            (item) => item.isChecked && item.location != null && !item.isError)
        .toList();
    totalProcessing = itemsToProcess.length;
    currentProcessing = 0;
    notifyListeners();

    if (itemsToProcess.isEmpty) {
      isProcessing = false;
      notifyListeners();
      return;
    }

    final bool useNativeExif = !Platform.isWindows;

    if (useNativeExif) {
      for (var item in itemsToProcess) {
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
          item.isError = false;
          item.errorMessage = null;
          _addTimelineMarker(item);
        } catch (e) {
          item.isError = true;
          item.isSuccess = false;
          item.errorMessage = 'Geotagging failed: $e';
        }
        currentProcessing++;
        if (currentProcessing % 5 == 0 ||
            currentProcessing == totalProcessing) {
          notifyListeners();
        }
      }
    } else {
      final String exe;
      try {
        exe = await _getExifToolExecutable();
      } catch (e) {
        for (var item in itemsToProcess) {
          item.isError = true;
          item.errorMessage = 'ExifTool not found: $e';
        }
        isProcessing = false;
        notifyListeners();
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final csvFile = File(
          '${tempDir.path}/geotags_${DateTime.now().millisecondsSinceEpoch}.csv');
      final argFile = File(
          '${tempDir.path}/args_${DateTime.now().millisecondsSinceEpoch}.txt');

      try {
        final csvBuf = StringBuffer();
        csvBuf.writeln(
            'SourceFile,GPSLatitude,GPSLatitudeRef,GPSLongitude,GPSLongitudeRef');

        final argBuf = StringBuffer();

        for (var item in itemsToProcess) {
          final loc = item.location!;
          final lat = loc.latitude.abs();
          final latRef = loc.latitude >= 0 ? 'N' : 'S';
          final lng = loc.longitude.abs();
          final lngRef = loc.longitude >= 0 ? 'E' : 'W';

          // Escape path for CSV
          final escapedPath = _escapeCsv(item.path);
          csvBuf.writeln('"$escapedPath",$lat,$latRef,$lng,$lngRef');

          // Add to argfile for the command line
          argBuf.writeln(item.path);
        }

        await csvFile.writeAsString(csvBuf.toString(), flush: true);
        await argFile.writeAsString(argBuf.toString(), flush: true);

        loadingMessage =
            'Applying Geotags to ${itemsToProcess.length} files...';
        notifyListeners();

        final process = await Process.start(exe, [
          '-progress',
          '-csv=${csvFile.path}',
          '-overwrite_original',
          '-@',
          argFile.path,
        ]);

        // Listen for progress updates on stdout
        // Format: [   1/500] Updating C:/path/to/file.jpg
        final progressRegex = RegExp(r'\[\s*(\d+)/\s*(\d+)\]');
        process.stdout.transform(utf8.decoder).listen((data) {
          final matches = progressRegex.allMatches(data);
          for (final match in matches) {
            final current = int.tryParse(match.group(1) ?? '');
            if (current != null &&
                current > 0 &&
                current <= itemsToProcess.length) {
              currentProcessing = current;

              // Mark the specific item as success in real-time
              // Progress [k/N] corresponds to itemsToProcess[k-1]
              final item = itemsToProcess[current - 1];
              if (!item.isSuccess) {
                item.isSuccess = true;
                item.isError = false;
                item.errorMessage = null;
                _addTimelineMarker(item);
              }
              notifyListeners();
            }
          }
        });

        final exitCode = await process.exitCode;

        if (exitCode != 0) {
          final stderr = await process.stderr.transform(utf8.decoder).join();
          loadingMessage = "Path too long? Try moving folder to C:\\Temp";
          throw Exception('ExifTool Batch Error: $stderr');
        }

        currentProcessing = totalProcessing;
      } catch (e) {
        for (var item in itemsToProcess) {
          item.isError = true;
          item.isSuccess = false;
          item.errorMessage = 'Batch Geotagging failed: $e';
        }
      } finally {
        // Cleanup temp files
        if (await csvFile.exists()) await csvFile.delete();
        if (await argFile.exists()) await argFile.delete();
      }
    }

    final manualItems =
        itemsToProcess.where((i) => i.isManualLocation && i.isSuccess);
    if (manualItems.isNotEmpty) {
      final lastManual = manualItems.last;
      historyMarkers.removeWhere((m) =>
          m.latitude == lastManual.location!.latitude &&
          m.longitude == lastManual.location!.longitude &&
          m.isManual);
      historyMarkers.add(TaggedHistoryItem(
        path: lastManual.path,
        latitude: lastManual.location!.latitude,
        longitude: lastManual.location!.longitude,
        isManual: true,
      ));
    }

    isProcessing = false;
    notifyListeners();

    if (autoClearList && !items.any((item) => item.isError)) {
      Future.delayed(const Duration(seconds: 1), () {
        clearFiles();
      });
    }
  }

  void _addTimelineMarker(GeotagItem item) {
    if (!item.isManualLocation) {
      historyMarkers.removeWhere((m) => m.path == item.path);
      historyMarkers.add(TaggedHistoryItem(
        path: item.path,
        latitude: item.location!.latitude,
        longitude: item.location!.longitude,
        isManual: false,
      ));
    }
  }
}
