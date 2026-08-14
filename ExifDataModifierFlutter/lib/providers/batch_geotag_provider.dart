import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/location_point.dart';

// ── Status of each discovered image ─────────────────────────────────────────

enum BatchItemStatus {
  pending, // Not yet processed
  matched, // Location matched – will be geotagged
  skippedHasGps, // Already has GPS
  noMatch, // No timeline point found
  skippedUnsupported, // Video / RAW / non-image
  done, // Successfully copied+geotagged
  copiedOnly, // Copied without geotag (skipped/no-match)
  error, // Error during processing
}

class BatchGeotagItem {
  final File file;
  final String path;
  final String filename;
  final String relativePath; // Relative to the image root folder

  bool hasExistingGps;
  bool isSupported; // false for video/RAW
  DateTime? dateTaken;
  LocationPoint? location;
  BatchItemStatus status;
  String? statusMessage;

  BatchGeotagItem({
    required this.file,
    required this.path,
    required this.filename,
    required this.relativePath,
    this.hasExistingGps = false,
    this.isSupported = true,
    this.dateTaken,
    this.location,
    this.status = BatchItemStatus.pending,
    this.statusMessage,
  });

  Color get statusColor {
    switch (status) {
      case BatchItemStatus.matched:
        return Colors.blue;
      case BatchItemStatus.skippedHasGps:
        return Colors.amber.shade700;
      case BatchItemStatus.noMatch:
        return Colors.red;
      case BatchItemStatus.skippedUnsupported:
        return Colors.grey;
      case BatchItemStatus.done:
        return Colors.green;
      case BatchItemStatus.copiedOnly:
        return Colors.orange;
      case BatchItemStatus.error:
        return Colors.red.shade700;
      case BatchItemStatus.pending:
        return Colors.grey;
    }
  }

  IconData get statusIcon {
    switch (status) {
      case BatchItemStatus.matched:
        return Icons.location_on;
      case BatchItemStatus.skippedHasGps:
        return Icons.warning_amber;
      case BatchItemStatus.noMatch:
        return Icons.location_off;
      case BatchItemStatus.skippedUnsupported:
        return Icons.block;
      case BatchItemStatus.done:
        return Icons.check_circle;
      case BatchItemStatus.copiedOnly:
        return Icons.copy;
      case BatchItemStatus.error:
        return Icons.error;
      case BatchItemStatus.pending:
        return Icons.hourglass_empty;
    }
  }
}

// ── Supported image extensions ───────────────────────────────────────────────

const _supportedImageExts = {
  'jpg',
  'jpeg',
  'png',
  'heic',
  'heif',
  'tif',
  'tiff',
  'webp',
  'avif',
};

const _unsupportedExts = {
  // Video
  'mp4', 'mov', 'avi', 'mkv', 'm4v', 'mts', 'm2ts', 'wmv', 'flv', 'webm',
  // RAW
  'raw', 'cr2', 'cr3', 'nef', 'arw', 'orf', 'rw2', 'dng', 'raf', 'pef',
  'srw', 'x3f', 'mrw',
};

// ── Provider ─────────────────────────────────────────────────────────────────

class BatchGeotagProvider extends ChangeNotifier {
  // ── Folder selections ────────────────────────────────────────────────────
  String? imageFolderPath;
  String? timelineFolderPath;
  String? outputFolderPath;

  // ── Loaded data ──────────────────────────────────────────────────────────
  List<BatchGeotagItem> items = [];
  List<LocationPoint> timelineLocations = [];
  List<String> loadedTimelineFiles = [];

  // ── Progress: scanning ───────────────────────────────────────────────────
  bool isScanning = false;
  int scannedCount = 0;
  int totalToScan = 0;

  // ── Progress: loading timelines ──────────────────────────────────────────
  bool isLoadingTimelines = false;
  int loadedTimelineCount = 0;
  int totalTimelines = 0;

  // ── Progress: matching ───────────────────────────────────────────────────
  bool isMatching = false;
  int matchedCount = 0;
  int totalToMatch = 0;

  // ── Progress: processing (copy + geotag) ────────────────────────────────
  bool isProcessing = false;
  int processedCount = 0;
  int totalToProcess = 0;

  // ── Cancellation ─────────────────────────────────────────────────────────
  bool _cancelScan = false;
  bool _cancelMatch = false;
  bool _cancelProcess = false;

  // ── Settings ─────────────────────────────────────────────────────────────
  int geotagTimezone = 7;
  int maxInterpolationGapMinutes = 120;

  /// Human-readable status string shown in UI
  String statusMessage = '';

  /// Last ExifTool diagnostic — set after every _batchReadExif run so the
  /// screen can show it as a toast (null = no result yet / already consumed).
  String? lastExifLog;

  // ── Stats ─────────────────────────────────────────────────────────────────
  int get countMatched =>
      items.where((i) => i.status == BatchItemStatus.matched).length;
  int get countDone =>
      items.where((i) => i.status == BatchItemStatus.done).length;
  int get countSkippedGps =>
      items.where((i) => i.status == BatchItemStatus.skippedHasGps).length;
  int get countNoMatch =>
      items.where((i) => i.status == BatchItemStatus.noMatch).length;
  int get countUnsupported =>
      items.where((i) => i.status == BatchItemStatus.skippedUnsupported).length;
  int get countError =>
      items.where((i) => i.status == BatchItemStatus.error).length;
  int get countCopiedOnly =>
      items.where((i) => i.status == BatchItemStatus.copiedOnly).length;

  bool get isBusy =>
      isScanning || isLoadingTimelines || isMatching || isProcessing;

  BatchGeotagProvider() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    geotagTimezone = prefs.getInt('geotagTimezone') ?? 7;
    await loadTimelineLocationsFromAppDb();
  }

  Future<void> loadTimelineLocationsFromAppDb() async {
    isLoadingTimelines = true;
    timelineLocations.clear();
    loadedTimelineFiles.clear();
    loadedTimelineCount = 0;
    statusMessage = 'Loading timelines from App Database…';
    notifyListeners();

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final activeDir = Directory(p.join(docDir.path, 'timelines', 'active'));
      if (!await activeDir.exists()) {
        statusMessage = 'App Database is empty.';
        isLoadingTimelines = false;
        notifyListeners();
        return;
      }

      final files = await activeDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      totalTimelines = files.length;

      if (totalTimelines == 0) {
        statusMessage = 'App Database has no timeline records.';
        isLoadingTimelines = false;
        notifyListeners();
        return;
      }

      final List<LocationPoint> allPoints = [];
      for (final file in files) {
        try {
          final content = await file.readAsString();
          final decoded = jsonDecode(content);
          final points = LocationPoint.parseAnyJson(decoded);
          allPoints.addAll(points);
          loadedTimelineFiles.add(p.basename(file.path));
          loadedTimelineCount++;
          statusMessage = 'Loaded $loadedTimelineCount / $totalTimelines timeline dates…';
          notifyListeners();
          await Future.delayed(Duration.zero);
        } catch (_) {}
      }

      allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      timelineLocations = allPoints.toSet().toList();
      timelineLocations.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      timelineFolderPath = activeDir.path;
      statusMessage = 'Loaded ${timelineLocations.length} locations from ${loadedTimelineFiles.length} dates in App Database.';
    } catch (e) {
      statusMessage = 'Error loading timelines from App Database: $e';
    }

    isLoadingTimelines = false;
    notifyListeners();
  }

  void cancelScan() {
    _cancelScan = true;
  }

  void cancelMatch() {
    _cancelMatch = true;
  }

  void cancelProcess() {
    _cancelProcess = true;
  }

  void setTimezone(int tz) async {
    geotagTimezone = tz;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('geotagTimezone', tz);
    notifyListeners();
  }

  void setMaxInterpolationGapMinutes(int val) {
    maxInterpolationGapMinutes = val;
    notifyListeners();
  }

  void setOutputFolder(String? folderPath) {
    outputFolderPath = folderPath;
    notifyListeners();
  }

  // ── Clear everything ──────────────────────────────────────────────────
  void reset() {
    items.clear();
    timelineLocations.clear();
    loadedTimelineFiles.clear();
    imageFolderPath = null;
    timelineFolderPath = null;
    outputFolderPath = null;
    statusMessage = '';
    notifyListeners();
  }

  void clearImages() {
    items.clear();
    imageFolderPath = null;
    statusMessage = '';
    notifyListeners();
  }

  void clearTimelines() {
    timelineLocations.clear();
    loadedTimelineFiles.clear();
    timelineFolderPath = null;
    // Reset match results
    for (var item in items) {
      if (item.status == BatchItemStatus.matched ||
          item.status == BatchItemStatus.noMatch) {
        item.status = BatchItemStatus.pending;
        item.location = null;
        item.statusMessage = null;
      }
    }
    statusMessage = '';
    notifyListeners();
  }

  // ── Step 1: Scan image folder recursively ─────────────────────────────────
  Future<void> scanImageFolder(String folderPath) async {
    _cancelScan = false;
    isScanning = true;
    imageFolderPath = folderPath;
    items.clear();
    scannedCount = 0;
    totalToScan = 0;
    statusMessage = 'Scanning folder…';
    notifyListeners();

    try {
      final dir = Directory(folderPath);
      // First, count total files for progress
      final allEntities =
          await dir.list(recursive: true, followLinks: false).toList();
      final allFiles = allEntities.whereType<File>().toList();
      totalToScan = allFiles.length;
      debugPrint(
          '[BatchScan] folder=$folderPath  totalFiles=${allFiles.length}');
      notifyListeners();

      // Collect image files
      final List<File> imageFiles = [];
      for (final file in allFiles) {
        if (_cancelScan) break;
        final ext = p.extension(file.path).toLowerCase().replaceAll('.', '');
        if (_supportedImageExts.contains(ext) ||
            _unsupportedExts.contains(ext)) {
          imageFiles.add(file);
        }
        scannedCount++;
        if (scannedCount % 50 == 0) {
          statusMessage = 'Found ${imageFiles.length} files…';
          notifyListeners();
          await Future.delayed(Duration.zero);
        }
      }

      if (_cancelScan) {
        statusMessage = 'Scan cancelled.';
        isScanning = false;
        notifyListeners();
        return;
      }

      // Build initial items
      for (final file in imageFiles) {
        final ext = p.extension(file.path).toLowerCase().replaceAll('.', '');
        final isSupported = _supportedImageExts.contains(ext);
        final relative = p.relative(file.path, from: folderPath);
        items.add(BatchGeotagItem(
          file: file,
          path: file.path,
          filename: p.basename(file.path),
          relativePath: relative,
          isSupported: isSupported,
          status: isSupported
              ? BatchItemStatus.pending
              : BatchItemStatus.skippedUnsupported,
          statusMessage: isSupported ? null : 'Unsupported format',
        ));
      }

      statusMessage =
          'Found ${items.length} files (${items.where((i) => i.isSupported).length} supported images).';
      debugPrint('[BatchScan] items=${items.length}  '
          'supported=${items.where((i) => i.isSupported).length}  '
          'unsupported=${items.where((i) => !i.isSupported).length}');

      // Read EXIF in batch on desktop
      final supportedFiles =
          items.where((i) => i.isSupported).map((i) => i.file).toList();
      debugPrint(
          '[BatchScan] calling _batchReadExif with ${supportedFiles.length} files');
      if (supportedFiles.isNotEmpty) {
        await _batchReadExif(supportedFiles);
      } else {
        debugPrint('[BatchScan] no supported files — skipping _batchReadExif');
      }
    } catch (e, st) {
      debugPrint('[BatchScan] ERROR in scanImageFolder: $e\n$st');
      statusMessage = 'Scan error: $e';
    }

    isScanning = false;
    _cancelScan = false;
    notifyListeners();
  }

  // ── Step 2: Load timeline files from folder ───────────────────────────────
  Future<void> loadTimelineFolder(String folderPath) async {
    _cancelScan = false;
    isLoadingTimelines = true;
    timelineFolderPath = folderPath;
    timelineLocations.clear();
    loadedTimelineFiles.clear();
    loadedTimelineCount = 0;
    statusMessage = 'Scanning timeline folder…';
    notifyListeners();

    try {
      final dir = Directory(folderPath);
      final allFiles = await dir
          .list(recursive: true, followLinks: false)
          .where((e) => e is File && e.path.toLowerCase().endsWith('.json'))
          .cast<File>()
          .toList();

      totalTimelines = allFiles.length;
      if (totalTimelines == 0) {
        statusMessage = 'No JSON files found in timeline folder.';
        isLoadingTimelines = false;
        notifyListeners();
        return;
      }

      final List<LocationPoint> allPoints = [];
      for (final file in allFiles) {
        if (_cancelScan) break;
        try {
          final content = await file.readAsString();
          final decoded = jsonDecode(content);
          final points = LocationPoint.parseAnyJson(decoded);
          allPoints.addAll(points);
          loadedTimelineFiles.add(p.basename(file.path));
          loadedTimelineCount++;
          statusMessage =
              'Loaded $loadedTimelineCount / $totalTimelines timeline files…';
          notifyListeners();
          await Future.delayed(Duration.zero);
        } catch (_) {
          // Skip invalid files
        }
      }

      // Sort and deduplicate by timestamp
      allPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      timelineLocations = allPoints.toSet().toList();
      timelineLocations.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      statusMessage =
          'Loaded ${timelineLocations.length} location points from ${loadedTimelineFiles.length} files.';
    } catch (e) {
      statusMessage = 'Timeline load error: $e';
    }

    isLoadingTimelines = false;
    _cancelScan = false;
    notifyListeners();
  }

  // ── Step 3: Match locations ───────────────────────────────────────────────
  Future<void> matchLocations() async {
    if (items.isEmpty) return;

    _cancelMatch = false;
    isMatching = true;
    matchedCount = 0;

    final candidates =
        items.where((i) => i.isSupported && !i.hasExistingGps).toList();
    totalToMatch = candidates.length;
    statusMessage = 'Matching locations…';
    notifyListeners();

    for (final item in candidates) {
      if (_cancelMatch) break;

      matchedCount++;
      if (matchedCount % 10 == 0 || matchedCount == totalToMatch) {
        statusMessage = 'Matching $matchedCount / $totalToMatch…';
        notifyListeners();
        await Future.delayed(Duration.zero);
      }

      if (timelineLocations.isEmpty) {
        item.status = BatchItemStatus.noMatch;
        item.statusMessage = 'No timeline loaded';
        continue;
      }

      try {
        final DateTime baseTime =
            item.dateTaken ?? (await item.file.stat()).modified;
        final fileTime = DateTime.utc(
          baseTime.year,
          baseTime.month,
          baseTime.day,
          baseTime.hour,
          baseTime.minute,
          baseTime.second,
          baseTime.millisecond,
        ).subtract(Duration(hours: geotagTimezone));

        final location = _findLocation(fileTime);
        if (location != null) {
          item.location = location;
          item.status = BatchItemStatus.matched;
          item.statusMessage =
              '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}';
        } else {
          item.status = BatchItemStatus.noMatch;
          item.statusMessage = 'No timeline point found';
        }
      } catch (e) {
        item.status = BatchItemStatus.noMatch;
        item.statusMessage = 'Match error: $e';
      }
    }

    // Mark existing-GPS items
    for (final item in items.where((i) => i.isSupported && i.hasExistingGps)) {
      item.status = BatchItemStatus.skippedHasGps;
      item.statusMessage = 'Already has GPS';
    }

    isMatching = false;
    if (_cancelMatch) {
      statusMessage = 'Matching cancelled.';
    } else {
      statusMessage =
          'Matched: $countMatched | Has GPS: $countSkippedGps | No match: $countNoMatch | Unsupported: $countUnsupported';
    }
    _cancelMatch = false;
    notifyListeners();
  }

  LocationPoint? _findLocation(DateTime fileTime) {
    if (timelineLocations.isEmpty) return null;

    // If before first point (within 30 min)
    if (fileTime.isBefore(timelineLocations.first.timestamp)) {
      final diff = timelineLocations.first.timestamp.difference(fileTime).abs();
      return diff.inMinutes <= 30 ? timelineLocations.first : null;
    }

    // If after last point (within 30 min)
    if (fileTime.isAfter(timelineLocations.last.timestamp)) {
      final diff = fileTime.difference(timelineLocations.last.timestamp).abs();
      return diff.inMinutes <= 30 ? timelineLocations.last : null;
    }

    final idx = _binarySearchTimeline(fileTime);
    if (idx >= 0 && idx < timelineLocations.length - 1) {
      final prevPoint = timelineLocations[idx];
      final nextPoint = timelineLocations[idx + 1];
      final gapDuration = nextPoint.timestamp.difference(prevPoint.timestamp);
      final gapMins = gapDuration.inMinutes;

      if (gapMins > maxInterpolationGapMinutes) {
        final prevDiff = fileTime.difference(prevPoint.timestamp).abs();
        final nextDiff = nextPoint.timestamp.difference(fileTime).abs();
        final closest = prevDiff < nextDiff ? prevPoint : nextPoint;
        final minDiff = prevDiff < nextDiff ? prevDiff : nextDiff;
        return minDiff.inMinutes <= 30 ? closest : null;
      }

      final totalDiffSc = gapDuration.inSeconds;
      if (totalDiffSc <= 0) return prevPoint;
      final elapsedSc = fileTime.difference(prevPoint.timestamp).inSeconds;
      final ratio = elapsedSc / totalDiffSc;
      return LocationPoint(
        latitude: prevPoint.latitude +
            (nextPoint.latitude - prevPoint.latitude) * ratio,
        longitude: prevPoint.longitude +
            (nextPoint.longitude - prevPoint.longitude) * ratio,
        timestamp: fileTime,
      );
    }
    return null;
  }

  int _binarySearchTimeline(DateTime target) {
    int lo = 0;
    int hi = timelineLocations.length - 2;
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
    return hi;
  }

  // ── Step 4: Process (copy + geotag) ──────────────────────────────────────
  Future<void> processAndCopy(String outputFolder) async {
    if (items.isEmpty) return;

    _cancelProcess = false;
    isProcessing = true;
    outputFolderPath = outputFolder;
    processedCount = 0;
    totalToProcess = items.length;
    statusMessage = 'Starting batch copy…';
    notifyListeners();

    // Ensure output folders exist
    await Directory(outputFolder).create(recursive: true);
    final noMatchFolder = p.join(outputFolder, 'no_match');
    await Directory(noMatchFolder).create(recursive: true);

    // Split items into three groups
    final toGeotag =
        items.where((i) => i.status == BatchItemStatus.matched).toList();
    // Items that had no timeline match → separate subfolder
    final toNoMatchFolder =
        items.where((i) => i.status == BatchItemStatus.noMatch).toList();
    // Items already geotagged or unsupported → main output folder
    final toCopyMain = items
        .where((i) =>
            i.status == BatchItemStatus.skippedHasGps ||
            i.status == BatchItemStatus.skippedUnsupported)
        .toList();

    // ── Copy no-match items to 'no_match/' subfolder ──────────────────────
    for (final item in toNoMatchFolder) {
      if (_cancelProcess) break;
      try {
        final destPath = p.join(noMatchFolder, item.filename);
        final destFile = await _resolveDestPath(destPath);
        await item.file.copy(destFile.path);
        item.status = BatchItemStatus.copiedOnly;
        item.statusMessage = 'Copied to no_match/${p.basename(destFile.path)}';
      } catch (e) {
        item.status = BatchItemStatus.error;
        item.statusMessage = 'Copy error: $e';
      }
      processedCount++;
      if (processedCount % 10 == 0 || processedCount == totalToProcess) {
        statusMessage =
            'Copying no-match files… $processedCount / $totalToProcess';
        notifyListeners();
        await Future.delayed(Duration.zero);
      }
    }

    if (_cancelProcess) {
      isProcessing = false;
      statusMessage = 'Processing cancelled.';
      _cancelProcess = false;
      notifyListeners();
      return;
    }

    // ── Copy skipped (has GPS / unsupported) to main output folder ─────────
    for (final item in toCopyMain) {
      if (_cancelProcess) break;
      try {
        final destPath = p.join(outputFolder, item.filename);
        final destFile = await _resolveDestPath(destPath);
        await item.file.copy(destFile.path);
        item.status = BatchItemStatus.copiedOnly;
        item.statusMessage = 'Copied to ${p.basename(destFile.path)}';
      } catch (e) {
        item.status = BatchItemStatus.error;
        item.statusMessage = 'Copy error: $e';
      }
      processedCount++;
      if (processedCount % 10 == 0 || processedCount == totalToProcess) {
        statusMessage =
            'Copying skipped files… $processedCount / $totalToProcess';
        notifyListeners();
        await Future.delayed(Duration.zero);
      }
    }

    if (_cancelProcess) {
      isProcessing = false;
      statusMessage = 'Processing cancelled.';
      _cancelProcess = false;
      notifyListeners();
      return;
    }

    // ── Geotag matched items via ExifTool ─────────────────────────────────
    if (toGeotag.isNotEmpty) {
      final geotaggedFolder = p.join(outputFolder, 'geotagged');
      await Directory(geotaggedFolder).create(recursive: true);
      await _geotagAndCopy(toGeotag, outputFolder, geotaggedFolder);
    }

    isProcessing = false;
    _cancelProcess = false;
    statusMessage =
        'Done! ✓ Geotagged: $countDone | Copied: $countCopiedOnly | Errors: $countError'
        ' — Geotagged copies also in geotagged/ | No-match in no_match/';
    notifyListeners();
  }

  /// Copies [toGeotag] items to [outputFolder], runs ExifTool to write GPS
  /// tags in-place, then copies each successfully geotagged file into
  /// [geotaggedFolder] so the user gets both a mixed root view and a clean
  /// geotagged-only subfolder.
  Future<void> _geotagAndCopy(List<BatchGeotagItem> toGeotag,
      String outputFolder, String geotaggedFolder) async {
    // ── Step A: Copy originals into main output folder ────────────────────
    statusMessage = 'Copying ${toGeotag.length} images to output…';
    notifyListeners();

    // Map from copied-file-path → item, used after geotagging to duplicate
    // into the geotagged/ subfolder.
    final Map<String, BatchGeotagItem> pathToItem = {};

    final List<BatchGeotagItem> copiedItems = [];
    for (final item in toGeotag) {
      if (_cancelProcess) break;
      try {
        final destPath = p.join(outputFolder, item.filename);
        final destFile = await _resolveDestPath(destPath);
        await item.file.copy(destFile.path);
        // Temporarily hold the dest path in statusMessage for the geotag step
        item.statusMessage = destFile.path;
        pathToItem[destFile.path] = item;
        copiedItems.add(item);
      } catch (e) {
        item.status = BatchItemStatus.error;
        item.statusMessage = 'Copy error: $e';
      }
      processedCount++;
      if (processedCount % 10 == 0) {
        statusMessage = 'Copying $processedCount / $totalToProcess…';
        notifyListeners();
        await Future.delayed(Duration.zero);
      }
    }

    if (_cancelProcess || copiedItems.isEmpty) return;

    // ── Step B: Geotag copied files via ExifTool batch CSV ────────────────
    statusMessage = 'Geotagging ${copiedItems.length} images…';
    notifyListeners();

    try {
      final exe = await _getExifToolExecutable();
      final tempDir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final csvFile = File('${tempDir.path}/batch_geotags_$ts.csv');
      final argFile = File('${tempDir.path}/batch_args_$ts.txt');

      final csvBuf = StringBuffer();
      csvBuf.writeln(
          'SourceFile,GPSLatitude,GPSLatitudeRef,GPSLongitude,GPSLongitudeRef');
      final argBuf = StringBuffer();

      for (final item in copiedItems) {
        final destPath = item.statusMessage!;
        final loc = item.location!;
        final lat = loc.latitude.abs();
        final latRef = loc.latitude >= 0 ? 'N' : 'S';
        final lng = loc.longitude.abs();
        final lngRef = loc.longitude >= 0 ? 'E' : 'W';
        csvBuf.writeln('"${_escapeCsv(destPath)}",$lat,$latRef,$lng,$lngRef');
        if (Platform.isWindows) {
          try { await Process.run('attrib', ['-r', destPath]); } catch (_) {}
        }
        final tmpFile = File('${destPath}_exiftool_tmp');
        if (await tmpFile.exists()) {
          try {
            if (Platform.isWindows) {
              await Process.run('attrib', ['-r', tmpFile.path]);
            }
            await tmpFile.delete();
          } catch (_) {}
        }
        argBuf.writeln(destPath);
      }

      await csvFile.writeAsString(csvBuf.toString(), flush: true);
      await argFile.writeAsString(argBuf.toString(), flush: true);

      final process = await Process.start(exe, [
        '-progress',
        '-csv=${csvFile.path}',
        '-overwrite_original',
        '-@',
        argFile.path,
      ]);

      final progressRegex = RegExp(r'\[\s*(\d+)/\s*(\d+)\]');
      process.stdout.transform(utf8.decoder).listen((data) {
        final matches = progressRegex.allMatches(data);
        for (final match in matches) {
          final current = int.tryParse(match.group(1) ?? '');
          if (current != null && current > 0 && current <= copiedItems.length) {
            final item = copiedItems[current - 1];
            item.status = BatchItemStatus.done;
            item.statusMessage =
                'Geotagged: ${item.location!.latitude.toStringAsFixed(5)}, '
                '${item.location!.longitude.toStringAsFixed(5)}';
            processedCount++;
            notifyListeners();
          }
        }
      });

      final exitCode = await process.exitCode;

      if (exitCode != 0) {
        for (final item
            in copiedItems.where((i) => i.status != BatchItemStatus.done)) {
          item.status = BatchItemStatus.error;
          item.statusMessage = 'ExifTool error';
        }
      } else {
        for (final item in copiedItems) {
          if (item.status == BatchItemStatus.matched) {
            item.status = BatchItemStatus.done;
            item.statusMessage =
                'Geotagged: ${item.location!.latitude.toStringAsFixed(5)}, '
                '${item.location!.longitude.toStringAsFixed(5)}';
          }
        }
      }

      // Cleanup temp files
      if (await csvFile.exists()) await csvFile.delete();
      if (await argFile.exists()) await argFile.delete();
    } catch (e) {
      for (final item in copiedItems) {
        if (item.status != BatchItemStatus.done) {
          item.status = BatchItemStatus.error;
          item.statusMessage = 'Geotag error: $e';
        }
      }
      notifyListeners();
      return;
    }

    // ── Step C: Copy geotagged files from main folder → geotagged/ ────────
    statusMessage = 'Copying geotagged files to geotagged/…';
    notifyListeners();

    for (final item in copiedItems) {
      if (item.status != BatchItemStatus.done) continue;
      // item.statusMessage currently holds the gps coords string —
      // recover the main-output path from pathToItem via reverse lookup.
      final mainPath = pathToItem.entries
          .firstWhere((e) => e.value == item, orElse: () => MapEntry('', item))
          .key;
      if (mainPath.isEmpty) continue;
      try {
        final subDest = p.join(geotaggedFolder, p.basename(mainPath));
        final subDestFile = await _resolveDestPath(subDest);
        await File(mainPath).copy(subDestFile.path);
        // Append folder hint to status message
        item.statusMessage =
            '${item.statusMessage} → geotagged/${p.basename(subDestFile.path)}';
      } catch (_) {
        // Non-fatal: main copy already exists and is geotagged
      }
    }

    notifyListeners();
  }

  /// Returns a file path that doesn't conflict with existing files,
  /// adding _1, _2, etc. suffix if needed.
  Future<File> _resolveDestPath(String destPath) async {
    if (!await File(destPath).exists()) return File(destPath);
    final dir = p.dirname(destPath);
    final ext = p.extension(destPath);
    final name = p.basenameWithoutExtension(destPath);
    int counter = 1;
    while (true) {
      final candidate = p.join(dir, '${name}_$counter$ext');
      if (!await File(candidate).exists()) return File(candidate);
      counter++;
    }
  }

  // ── EXIF batch read ───────────────────────────────────────────────────────
  Future<void> _batchReadExif(List<File> files) async {
    if (files.isEmpty) return;
    statusMessage = 'Reading EXIF for ${files.length} files…';
    notifyListeners();

    try {
      final exe = await _getExifToolExecutable();
      final batches = _getDynamicChunks<File>(files, (f) => f.path, 100);

      for (final chunk in batches) {
        if (_cancelScan) break;

        final args = [
          '-GPSLatitude',
          '-DateTimeOriginal',
          '-d',
          '%Y-%m-%dT%H:%M:%S',
          '-f',
          '-csv',
          ...chunk.map((f) => f.path),
        ];

        debugPrint('[BatchExif] CMD: $exe ${args.take(6).join(' ')} '
            '... (${chunk.length} files)');

        final result = await Process.run(exe, args);

        final rawOut = result.stdout.toString().trim();
        final rawErr = result.stderr.toString().trim();

        debugPrint('[BatchExif] exitCode=${result.exitCode} '
            'stdout=${rawOut.length} chars  '
            'stderr=${rawErr.isEmpty ? "(empty)" : rawErr.substring(0, rawErr.length.clamp(0, 500))}');
        if (rawOut.isNotEmpty) {
          debugPrint('[BatchExif] stdout preview:\n'
              '${rawOut.substring(0, rawOut.length.clamp(0, 2000))}');
        }

        // ExifTool exit codes:
        //   0 = all OK
        //   1 = minor warning (e.g. one unreadable file, missing tag) — still
        //       outputs valid CSV rows for all other files, so we MUST parse.
        //   2 = fatal error — no usable output.
        if (result.exitCode >= 2) {
          final msg = 'ExifTool fatal (exit ${result.exitCode})'
              '${rawErr.isNotEmpty ? ":\n${rawErr.substring(0, rawErr.length.clamp(0, 400))}" : ""}';
          debugPrint('[BatchExif] FATAL: $msg');
          lastExifLog = msg;
          notifyListeners();
          continue;
        }
        if (rawOut.isEmpty) {
          final msg = 'ExifTool exit ${result.exitCode} — no output.'
              '${rawErr.isNotEmpty ? "\nstderr: ${rawErr.substring(0, rawErr.length.clamp(0, 400))}" : ""}';
          debugPrint('[BatchExif] empty stdout: $msg');
          lastExifLog = msg;
          notifyListeners();
          continue;
        }
        // exit-code 1 = minor warning but CSV is still valid — surface the warning
        if (result.exitCode == 1 && rawErr.isNotEmpty) {
          lastExifLog = 'ExifTool warning (some files skipped):\n'
              '${rawErr.substring(0, rawErr.length.clamp(0, 400))}';
          notifyListeners();
        }

        final lines = rawOut.split('\n');
        if (lines.isEmpty) continue;

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

          BatchGeotagItem? item;
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
          }
        }
        notifyListeners();
      }
    } catch (e, st) {
      final msg = 'ExifTool error: $e';
      debugPrint('[BatchExif] ERROR: $e\n$st');
      lastExifLog = msg;
      notifyListeners();
    }

    statusMessage =
        'EXIF read complete. ${items.where((i) => i.hasExistingGps).length} already have GPS.';
    notifyListeners();
  }

  // ── ExifTool helper ───────────────────────────────────────────────────────
  Future<String> _getExifToolExecutable() async {
    try {
      final result = await Process.run('exiftool', ['-ver']);
      if (result.exitCode == 0) return 'exiftool';
    } catch (_) {}

    if (Platform.isWindows) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final installedExe = File(p.join(exeDir.path, 'exiftool.exe'));
        if (await installedExe.exists()) return installedExe.path;
      } catch (_) {}

      const cPath = 'C:\\exiftool\\exiftool.exe';
      if (await File(cPath).exists()) return cPath;
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(p.join(appDir.path, 'exiftool.exe'));
      if (!await exeFile.exists()) {
        final data = await rootBundle.load('assets/bin/exiftool.exe');
        final bytes = data.buffer.asUint8List();
        await exeFile.writeAsBytes(bytes);
      }
      return exeFile.path;
    } catch (_) {
      return 'exiftool';
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────
  List<List<T>> _getDynamicChunks<T>(
      List<T> items, String Function(T) getPath, int reservedLength) {
    const int maxWinCmdLength = 8000;
    List<List<T>> chunks = [];
    List<T> currentChunk = [];
    int currentLength = reservedLength;

    for (var item in items) {
      final path = getPath(item);
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
    if (currentChunk.isNotEmpty) chunks.add(currentChunk);
    return chunks;
  }

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

  String _escapeCsv(String text) {
    if (text.contains('"')) {
      return text.replaceAll('"', '""');
    }
    return text;
  }
}
