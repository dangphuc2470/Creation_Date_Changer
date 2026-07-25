import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:exif/exif.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/location_point.dart';
import '../providers/app_state_provider.dart';
import '../providers/settings_provider.dart';
import '../services/location_manager.dart';
import '../constants/timeline_constants.dart';
import '../utils/geo_utils.dart';

// ═══════════════════════════════════════════════════════════════════════════
// SECTION: Top-level helpers — ProjectionResult, IndexPoint, PhotoEntry
// ═══════════════════════════════════════════════════════════════════════════

class ProjectionResult {
  final int insertIndex;
  final LatLng point;
  final double t;
  final double distance;

  ProjectionResult({
    required this.insertIndex,
    required this.point,
    required this.t,
    required this.distance,
  });
}

ProjectionResult? _getNearestProjection(
    LatLng cursor, List<LocationPoint> points) {
  if (points.length < 2) return null;

  ProjectionResult? bestResult;
  double minDistanceSq = double.infinity;

  final cx = cursor.latitude;
  final cy = cursor.longitude;

  for (int i = 0; i < points.length - 1; i++) {
    final ax = points[i].latitude;
    final ay = points[i].longitude;
    final bx = points[i + 1].latitude;
    final by = points[i + 1].longitude;

    final abx = bx - ax;
    final aby = by - ay;

    final acx = cx - ax;
    final acy = cy - ay;

    final abLenSq = abx * abx + aby * aby;
    double t = 0.0;
    if (abLenSq > 0) {
      t = (acx * abx + acy * aby) / abLenSq;
      t = t.clamp(0.0, 1.0);
    }

    final px = ax + t * abx;
    final py = ay + t * aby;

    final dx = cx - px;
    final dy = cy - py;
    final distSq = dx * dx + dy * dy;

    if (distSq < minDistanceSq) {
      minDistanceSq = distSq;
      bestResult = ProjectionResult(
        insertIndex: i + 1,
        point: LatLng(px, py),
        t: t,
        distance: distSq,
      );
    }
  }

  return bestResult;
}

class IndexPoint {
  final int index;
  final LocationPoint point;
  IndexPoint(this.index, this.point);
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo entry: dropped/picked photo with optional EXIF GPS
// ─────────────────────────────────────────────────────────────────────────────
class PhotoEntry {
  final File file;
  final String filename;

  /// Stored as DateTime.utc() but with LOCAL time values from EXIF.
  /// Subtract timezone offset to get proper UTC for comparisons.
  DateTime? dateTaken;

  /// GPS from EXIF (or user-dragged). Null when photo has no GPS.
  LatLng? gpsLatLng;

  /// Position inferred by interpolating timeline at dateTaken.
  /// Only populated for photos without EXIF GPS.
  LatLng? interpolatedLatLng;
  bool addedToTimeline = false;

  PhotoEntry({required this.file, required this.filename});

  /// Position shown on map: EXIF GPS (may be dragged) or interpolated.
  LatLng? get assignedLatLng => gpsLatLng ?? interpolatedLatLng;
  bool get hasExifGps => gpsLatLng != null;
}

class MapViewerScreen extends StatefulWidget {
  const MapViewerScreen({super.key});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  AnimationController? _mapAnimationController;

  DateTime? _selectedDate;
  bool _showCalendar = false;
  bool _viewAsPath = true;
  double _sidebarWidth = 380.0;

  // Hover state (non-edit mode)
  LocationPoint? _hoveredPoint;
  Color? _hoveredColor;
  LatLng? _hoveredLatLng;
  ProjectionResult? _hoveredProjection; // Hover state (edit mode)

  // Selected point index (edit mode)
  int? _selectedPointIndex;
  bool _isDraggingPoint = false;
  int? _selectedTimelineItemIndex;
  int? _hoveredTimelineItemIndex;
  LocationPoint? _previousDayLastStayPoint;
  bool _isDraggingHoverDot = false;
  DateTime? _draggedHoverDotTime;
  int? _draggedHoverDotInsertIndex;
  LatLng? _draggedHoverDotCurrentLatLng;
  TimelinePath? _draggedHoverDotSegment;
  bool _autoSnapOnDrag = false;
  bool _isRightClickSelecting = false;
  LatLng? _rightClickStartLatLng;
  LatLng? _rightClickCurrentLatLng;
  bool _isDraggingPlace = false;
  int? _draggingPlaceIndex;
  LatLng? _draggingPlaceStartLatLng;
  LatLng? _draggedPlaceCurrentLatLng;
  final Map<String, List<LocationPoint>> _unsnappedSegmentBackups = {};
  bool _isSaving = false;
  int _savingCount = 0; // tracks concurrent saves

  // ── Photo layer ─────────────────────────────────────────────────────────
  final List<PhotoEntry> _photos = [];
  bool _isDraggingPhotoOver = false;
  PhotoEntry? _selectedPhoto; // for strip/preview
  bool _showPhotoGrid = false;

  // ── Import Progress State ────────────────────────────────────────────────
  bool _isImportingPhotos = false;
  int _importTotalPhotos = 0;
  int _importProcessedPhotos = 0;
  String _importCurrentStatus = '';

  // ── Photo drag on map ─────────────────────────────────────────────────
  PhotoEntry? _draggingPhoto;
  bool _isDraggingPhoto = false;

  // ── Multi-select (Ctrl+click) ─────────────────────────────────────────
  final Set<PhotoEntry> _selectedPhotoSet = {};

  // ── Cached photo-assigned timeline items ──────────────────────────────
  /// Built by _assignPhotosToTimelineItems(); shared by sidebar + map.
  List<TimelineItem>? _timelineItemsWithPhotos;

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Lifecycle — initState, dispose, load/save last selected date
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadLastSelectedDate();
  }

  Future<void> _loadLastSelectedDate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedDateStr = prefs.getString('last_selected_map_date');
      if (savedDateStr != null) {
        final parsedDate = DateTime.tryParse(savedDateStr);
        if (parsedDate != null) {
          setState(() {
            _selectedDate = parsedDate;
          });
          _loadPointsForSelectedDate();
        }
      }
    } catch (e) {
      debugPrint('Error loading last selected map date: $e');
    }
  }

  Future<void> _saveLastSelectedDate(DateTime date) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'last_selected_map_date', DateFormat('yyyy-MM-dd').format(date));
    } catch (e) {
      debugPrint('Error saving last selected map date: $e');
    }
  }

  void _loadPointsForSelectedDate(
      {bool fitBounds = true, bool keepSelection = false}) async {
    setState(() {
      if (!keepSelection) {
        _selectedTimelineItemIndex = null;
      }
      _timelineItemsWithPhotos =
          null; // clear so sidebar rebuilds with fresh assign
    });
    if (_selectedDate == null) return;
    _saveLastSelectedDate(_selectedDate!);
    final appState = context.read<AppStateProvider>();

    // Try to load previous day's last stay point to show stay continuity
    LocationPoint? prevLastStay;
    try {
      final prevDate = _selectedDate!.subtract(const Duration(days: 1));
      final prevDateInfo = appState.allDates.firstWhere(
        (d) =>
            d.date.year == prevDate.year &&
            d.date.month == prevDate.month &&
            d.date.day == prevDate.day,
        orElse: () => DateInfo(
          date: prevDate,
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );

      if (prevDateInfo.filePath.isNotEmpty) {
        final prevPoints =
            await LocationManager.loadLocationFile(prevDateInfo.filePath);
        if (!mounted) return;
        if (prevPoints.isNotEmpty) {
          final settings = context.read<SettingsProvider>();
          final double timeOffset = settings.geotagTimezone.toDouble();
          final prevItems = _clusterTimelineRaw(prevPoints, timeOffset);
          for (int k = prevItems.length - 1; k >= 0; k--) {
            if (prevItems[k] is TimelinePlace) {
              final stay = prevItems[k] as TimelinePlace;
              prevLastStay = LocationPoint(
                latitude: stay.center.latitude,
                longitude: stay.center.longitude,
                timestamp: stay.endTime,
              );
              break;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading previous day last stay point: $e');
    }

    setState(() {
      _previousDayLastStayPoint = prevLastStay;
    });

    final dateInfo = appState.allDates.firstWhere(
      (d) =>
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.date.day == _selectedDate!.day,
      orElse: () => DateInfo(
        date: _selectedDate!,
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    if (dateInfo.filePath.isNotEmpty) {
      final points = await LocationManager.loadLocationFile(dateInfo.filePath);
      if (!mounted) return;
      appState.setSelectedDatePath(dateInfo, points);

      // Rebuild photo-timeline assignments with fresh points
      if (_photos.isNotEmpty) {
        final settings = context.read<SettingsProvider>();
        _assignPhotosToTimelineItems(
            points, settings.geotagTimezone.toDouble());
      }

      if (fitBounds) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fitBounds();
        });
      }
    } else {
      appState.setSelectedDatePath(dateInfo, []);
      if (_photos.isNotEmpty) {
        final settings = context.read<SettingsProvider>();
        _assignPhotosToTimelineItems([], settings.geotagTimezone.toDouble());
      }
    }
  }

  @override
  void dispose() {
    _mapAnimationController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Photo / EXIF — drag-drop, file picker, EXIF read, GPS→timeline
  // ─────────────────────────────────────────────────────────────────────────

  // ── Read EXIF from photo file (Header-only fast read) ──────────────────────
  Future<Uint8List> _readFileHeaderBytes(File file,
      {int maxHeaderBytes = 131072}) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        final length = await raf.length();
        final bytesToRead = length < maxHeaderBytes ? length : maxHeaderBytes;
        return await raf.read(bytesToRead);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return await file.readAsBytes();
    }
  }

  Future<void> _readExifFromPhoto(PhotoEntry entry) async {
    try {
      Map<String, IfdTag> tags = {};
      try {
        final headerBytes = await _readFileHeaderBytes(entry.file);
        tags = await readExifFromBytes(headerBytes);
      } catch (_) {
        try {
          // Fallback to full file if header parse fails
          final bytes = await entry.file.readAsBytes();
          tags = await readExifFromBytes(bytes);
        } catch (_) {}
      }
      if (tags.isEmpty) return;

      // Date
      final dateTag = tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'];
      if (dateTag != null) {
        final raw = dateTag.printable; // e.g. "2024:05:10 13:45:22"
        final parts = raw.split(' ');
        if (parts.length == 2) {
          final dateParts = parts[0].split(':');
          final timeParts = parts[1].split(':');
          if (dateParts.length == 3 && timeParts.length == 3) {
            try {
              entry.dateTaken = DateTime.utc(
                int.parse(dateParts[0]),
                int.parse(dateParts[1]),
                int.parse(dateParts[2]),
                int.parse(timeParts[0]),
                int.parse(timeParts[1]),
                int.parse(timeParts[2]),
              );
            } catch (_) {}
          }
        }
      }

      // GPS
      final latTag = tags['GPS GPSLatitude'];
      final latRef = tags['GPS GPSLatitudeRef'];
      final lngTag = tags['GPS GPSLongitude'];
      final lngRef = tags['GPS GPSLongitudeRef'];

      if (latTag != null && lngTag != null) {
        double? parseDms(IfdTag tag) {
          try {
            if (tag.values is IfdRatios) {
              final vals = tag.values as IfdRatios;
              if (vals.ratios.length >= 3) {
                final d = vals.ratios[0].numerator /
                    (vals.ratios[0].denominator == 0
                        ? 1
                        : vals.ratios[0].denominator);
                final m = vals.ratios[1].numerator /
                    (vals.ratios[1].denominator == 0
                        ? 1
                        : vals.ratios[1].denominator);
                final s = vals.ratios[2].numerator /
                    (vals.ratios[2].denominator == 0
                        ? 1
                        : vals.ratios[2].denominator);
                return d + m / 60 + s / 3600;
              }
            }
          } catch (_) {}
          return null;
        }

        final lat = parseDms(latTag);
        final lng = parseDms(lngTag);
        if (lat != null && lng != null) {
          double finalLat = lat;
          double finalLng = lng;
          if (latRef?.printable == 'S') finalLat = -finalLat;
          if (lngRef?.printable == 'W') finalLng = -finalLng;
          entry.gpsLatLng = LatLng(finalLat, finalLng);
        }
      }
    } catch (e) {
      debugPrint('EXIF read error for ${entry.filename}: $e');
    }
  }

  bool _isImageFile(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
        ext.endsWith('.png') ||
        ext.endsWith('.heic') ||
        ext.endsWith('.webp');
  }

  Future<List<File>> _collectAllImageFilesRecursively(
      List<File> inputFiles) async {
    final List<File> collectedFiles = [];
    final Set<String> visitedPaths = {};

    for (final file in inputFiles) {
      final path = file.path;
      if (visitedPaths.contains(path)) continue;
      visitedPaths.add(path);

      try {
        final type = await FileSystemEntity.type(path);
        if (type == FileSystemEntityType.directory) {
          final dir = Directory(path);
          await for (final entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is File && _isImageFile(entity.path)) {
              if (!visitedPaths.contains(entity.path)) {
                visitedPaths.add(entity.path);
                collectedFiles.add(entity);
              }
            }
          }
        } else if (type == FileSystemEntityType.file && _isImageFile(path)) {
          collectedFiles.add(file);
        }
      } catch (e) {
        debugPrint('Error inspecting file/directory $path: $e');
      }
    }
    return collectedFiles;
  }

  // ── Load photos (from drop or picker) ───────────────────────────────────
  Future<void> _loadPhotosFromFiles(List<File> files) async {
    setState(() {
      _isImportingPhotos = true;
      _importTotalPhotos = 0;
      _importProcessedPhotos = 0;
      _importCurrentStatus = 'Scanning files and directories...';
    });

    final allFiles = await _collectAllImageFilesRecursively(files);
    final newEntries = <PhotoEntry>[];
    for (final f in allFiles) {
      if (_photos.any((p) => p.file.path == f.path)) continue;
      final entry = PhotoEntry(
        file: f,
        filename:
            f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : f.path,
      );
      newEntries.add(entry);
    }

    if (newEntries.isEmpty) {
      if (mounted) {
        setState(() {
          _isImportingPhotos = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _importTotalPhotos = newEntries.length;
        _importProcessedPhotos = 0;
        _importCurrentStatus =
            'Reading EXIF metadata (0 / $_importTotalPhotos)...';
      });
    }

    // Read EXIF in chunks of 50 to maintain low RAM & 60FPS UI responsiveness
    const int batchSize = 50;
    for (int i = 0; i < newEntries.length; i += batchSize) {
      final batch = newEntries.sublist(
          i,
          i + batchSize > newEntries.length
              ? newEntries.length
              : i + batchSize);
      await Future.wait(batch.map(_readExifFromPhoto));
      if (mounted) {
        final processed = min(i + batchSize, newEntries.length);
        setState(() {
          _importProcessedPhotos = processed;
          _importCurrentStatus =
              'Reading EXIF metadata ($processed / $_importTotalPhotos)...';
        });
      }
    }
    if (!mounted) return;

    setState(() {
      _importCurrentStatus = 'Inserting photos into timeline...';
      _photos.addAll(newEntries);
    });

    // Auto-insert geotagged photos into timeline + rebuild assignments
    await _autoInsertGeotaggedPhotoPoints(newEntries);

    if (mounted) {
      setState(() {
        _isImportingPhotos = false;
      });
    }

    // Analyze unique dates in imported photos
    final Map<DateTime, int> importedDatesCount = {};
    for (final entry in newEntries) {
      if (entry.dateTaken != null) {
        final dayKey = DateTime(entry.dateTaken!.year, entry.dateTaken!.month,
            entry.dateTaken!.day);
        importedDatesCount[dayKey] = (importedDatesCount[dayKey] ?? 0) + 1;
      }
    }

    if (importedDatesCount.length == 1) {
      // Case 1: Photos belong to ONLY 1 unique date -> Silent + Auto open that date!
      final singleDate = importedDatesCount.keys.first;
      if (mounted) {
        setState(() => _selectedDate = singleDate);
        _loadPointsForSelectedDate();
      }
    } else if (importedDatesCount.length > 1 && mounted) {
      // Case 2: Photos belong to MULTIPLE dates -> Show dialog with dates & Go to Date buttons
      _showImportedDatesDialog(importedDatesCount, newEntries.length);
    }
  }

  void _showImportedDatesDialog(
      Map<DateTime, int> datesCount, int totalPhotos) {
    final sortedDates = datesCount.keys.toList()..sort();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.photo_library, color: Colors.deepPurple),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Imported $totalPhotos Photos (${datesCount.length} Dates)',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Photos imported across ${datesCount.length} dates:',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sortedDates.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final date = sortedDates[index];
                    final count = datesCount[date]!;
                    final dateStr =
                        DateFormat('yyyy-MM-dd (EEEE)').format(date);
                    final isCurrent = _selectedDate != null &&
                        _selectedDate!.year == date.year &&
                        _selectedDate!.month == date.month &&
                        _selectedDate!.day == date.day;

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        dateStr,
                        style: TextStyle(
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent ? Colors.deepPurple : null,
                        ),
                      ),
                      subtitle: Text('$count photo${count > 1 ? 's' : ''}'),
                      trailing: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          setState(() => _selectedDate = date);
                          _loadPointsForSelectedDate();
                        },
                        child: Text(isCurrent ? 'Viewing' : 'Go to Date'),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildImportProgressOverlay(BuildContext context) {
    final progress = _importTotalPhotos > 0
        ? (_importProcessedPhotos / _importTotalPhotos).clamp(0.0, 1.0)
        : null;

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Material(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            child: Container(
              padding: const EdgeInsets.all(24),
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.unarchive,
                            color: Colors.deepPurple, size: 24),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Importing Photos...',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Processing EXIF headers & GPS tags',
                              style:
                                  TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: Colors.deepPurple.shade50,
                      color: Colors.deepPurple,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _importTotalPhotos > 0
                            ? '$_importProcessedPhotos / $_importTotalPhotos photos'
                            : 'Scanning files...',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        progress != null ? '${(progress * 100).toInt()}%' : '',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepPurple,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _importCurrentStatus,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Insert photo GPS as a LocationPoint into timeline ───────────────────
  Future<void> _addPhotoGpsToTimeline(PhotoEntry photo) async {
    if (photo.gpsLatLng == null) return;
    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();

    final currentDateInfo = appState.allDates.firstWhere(
      (d) =>
          _selectedDate != null &&
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.date.day == _selectedDate!.day,
      orElse: () => DateInfo(
        date: _selectedDate ?? DateTime.now(),
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    // Determine timestamp: use photo's EXIF date (adjust for timezone offset)
    DateTime timestamp;
    if (photo.dateTaken != null) {
      final offset = settings.geotagTimezone;
      // dateTaken stored as local time in EXIF — convert to UTC
      timestamp =
          photo.dateTaken!.subtract(Duration(minutes: (offset * 60).toInt()));
    } else {
      timestamp = DateTime.now().toUtc();
    }

    final newPoint = LocationPoint(
      latitude: photo.gpsLatLng!.latitude,
      longitude: photo.gpsLatLng!.longitude,
      timestamp: timestamp,
    );

    List<LocationPoint> current = [];
    if (currentDateInfo.filePath.isNotEmpty) {
      current =
          await LocationManager.loadLocationFile(currentDateInfo.filePath);
    }

    // Insert in sorted order by timestamp
    current.add(newPoint);
    current.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    await appState.saveListPoints(currentDateInfo, current);
    _loadPointsForSelectedDate();

    setState(() {
      photo.addedToTimeline = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Added GPS from "${photo.filename}" to timeline '
            '(${photo.gpsLatLng!.latitude.toStringAsFixed(5)}, '
            '${photo.gpsLatLng!.longitude.toStringAsFixed(5)})'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Photo–Timeline integration helpers
  //  • _autoInsertGeotaggedPhotoPoints  – batch-insert GPS points into track
  //  • _currentDateInfo                 – DateInfo for current selected date
  //  • _interpolatePositionAtTime       – find LatLng on track at given time
  //  • _assignPhotosToTimelineItems     – match photos → Stay/Move items
  //  • _buildTimelinePhotoRows          – small thumbnail strip for sidebar
  //  • _applyInterpolatedGeotag         – promote interpolated → GPS
  // ─────────────────────────────────────────────────────────────────────────

  /// Batch-inserts a LocationPoint for each new geotagged photo into the
  /// current day's timeline file, then reloads via [_loadPointsForSelectedDate].
  /// If no photos have GPS, just rebuilds the assignment from existing points.
  Future<void> _autoInsertGeotaggedPhotoPoints(
      List<PhotoEntry> newEntries) async {
    if (!mounted) return;
    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final double tz = settings.geotagTimezone.toDouble();

    final gpsEntries = newEntries.where((e) => e.gpsLatLng != null).toList();
    if (gpsEntries.isEmpty) {
      // No GPS photos — just rebuild assignments from existing track
      final info = _currentDateInfo(appState);
      final pts = appState.activePaths[info.filePath] ?? [];
      _assignPhotosToTimelineItems(pts, tz);
      return;
    }

    if (_selectedDate == null) return;
    final cdi = _currentDateInfo(appState);
    List<LocationPoint> cur = cdi.filePath.isNotEmpty
        ? await LocationManager.loadLocationFile(cdi.filePath)
        : [];

    for (final entry in gpsEntries) {
      final ts = entry.dateTaken != null
          ? entry.dateTaken!.subtract(Duration(minutes: (tz * 60).toInt()))
          : DateTime.now().toUtc();
      cur.add(LocationPoint(
        latitude: entry.gpsLatLng!.latitude,
        longitude: entry.gpsLatLng!.longitude,
        timestamp: ts,
      ));
      entry.addedToTimeline = true;
    }
    cur.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await appState.saveListPoints(cdi, cur);
    if (!mounted) return;
    _loadPointsForSelectedDate(); // will call _assignPhotosToTimelineItems
  }

  /// Returns the [DateInfo] for the currently selected date, or a placeholder.
  DateInfo _currentDateInfo(AppStateProvider appState) {
    return appState.allDates.firstWhere(
      (d) =>
          _selectedDate != null &&
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.date.day == _selectedDate!.day,
      orElse: () => DateInfo(
        date: _selectedDate ?? DateTime.now(),
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );
  }

  /// Linearly interpolates a position on the track at [localTimeFakeUtc].
  /// [localTimeFakeUtc] stores EXIF local time in a DateTime.utc() container;
  /// subtract [tz] hours to convert to proper UTC before comparing timestamps.
  LatLng? _interpolatePositionAtTime(
      DateTime localTimeFakeUtc, List<LocationPoint> points, double tz) {
    if (points.isEmpty) return null;
    final utc = localTimeFakeUtc.subtract(Duration(minutes: (tz * 60).toInt()));
    if (utc.isBefore(points.first.timestamp)) return points.first.latLng;
    if (utc.isAfter(points.last.timestamp)) return points.last.latLng;
    for (int i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (utc.compareTo(a.timestamp) >= 0 && utc.compareTo(b.timestamp) <= 0) {
        final ms = b.timestamp.difference(a.timestamp).inMilliseconds;
        if (ms == 0) return a.latLng;
        final r = utc.difference(a.timestamp).inMilliseconds / ms;
        return LatLng(
          a.latitude + (b.latitude - a.latitude) * r,
          a.longitude + (b.longitude - a.longitude) * r,
        );
      }
    }
    return points.last.latLng;
  }

  /// Returns photos taken on the currently selected date (or all photos if no date selected).
  List<PhotoEntry> get _currentDatePhotos {
    if (_selectedDate == null) return _photos;
    final sel = _selectedDate!;
    return _photos.where((p) {
      if (p.dateTaken == null) return true;
      return p.dateTaken!.year == sel.year &&
          p.dateTaken!.month == sel.month &&
          p.dateTaken!.day == sel.day;
    }).toList();
  }

  /// Clusters [points] into [TimelineItem]s, then assigns each [PhotoEntry]
  /// in [_currentDatePhotos] to the item whose time range contains [dateTaken].
  /// For photos without GPS, also computes [PhotoEntry.interpolatedLatLng].
  /// Stores result in [_timelineItemsWithPhotos] and calls [setState].
  void _assignPhotosToTimelineItems(List<LocationPoint> points, double tz) {
    final items = _clusterTimeline(points, tz);

    // Reset existing assignments
    for (final item in items) {
      if (item is TimelinePlace) {
        item.geotaggedPhotos = [];
        item.ungeotaggedPhotos = [];
      } else if (item is TimelinePath) {
        item.geotaggedPhotos = [];
        item.ungeotaggedPhotos = [];
      }
    }

    final datePhotos = _currentDatePhotos;
    for (final photo in datePhotos) {
      // Compute interpolated position for ungeotagged photos
      if (photo.gpsLatLng == null &&
          photo.dateTaken != null &&
          points.isNotEmpty) {
        photo.interpolatedLatLng =
            _interpolatePositionAtTime(photo.dateTaken!, points, tz);
      }

      if (photo.dateTaken == null) continue;

      final utc =
          photo.dateTaken!.subtract(Duration(minutes: (tz * 60).toInt()));

      TimelineItem? best;
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (utc.compareTo(item.startTime) >= 0 &&
            utc.compareTo(item.endTime) <= 0) {
          best = item;
          break;
        }
        // Let the last segment capture photos taken after its endTime
        if (i == items.length - 1 && utc.isAfter(item.startTime)) {
          best = item;
        }
      }
      if (best == null) continue;

      if (photo.gpsLatLng != null) {
        if (best is TimelinePlace) best.geotaggedPhotos.add(photo);
        if (best is TimelinePath) best.geotaggedPhotos.add(photo);
      } else if (photo.interpolatedLatLng != null) {
        if (best is TimelinePlace) best.ungeotaggedPhotos.add(photo);
        if (best is TimelinePath) best.ungeotaggedPhotos.add(photo);
      }
    }

    if (mounted) setState(() => _timelineItemsWithPhotos = items);
  }

  // ── Photo helpers for Timeline tiles ──────────────────────────────────
  final Set<int> _expandedPhotoGrids = {};

  void _geotagAllInItem(TimelineItem item) {
    final ungeotagged = (item is TimelinePlace)
        ? item.ungeotaggedPhotos
        : (item is TimelinePath ? item.ungeotaggedPhotos : <PhotoEntry>[]);

    final photosToTag = List<PhotoEntry>.from(ungeotagged);
    if (photosToTag.isEmpty) return;

    setState(() {
      for (final photo in photosToTag) {
        if (photo.interpolatedLatLng != null) {
          photo.gpsLatLng = photo.interpolatedLatLng;
          photo.interpolatedLatLng = null;
          photo.addedToTimeline = true;
        }
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Applied geotags to ${photosToTag.length} photos'),
      backgroundColor: Colors.teal,
      duration: const Duration(seconds: 2),
    ));

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final pts = appState.activePaths[_currentDateInfo(appState).filePath] ?? [];
    _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());
  }

  /// Modify Photo Geotag -> Snap photo GPS coordinate to timeline interpolated location
  void _modifyGeotagsFromTimelineInItem(TimelineItem item) {
    final geotagged = (item is TimelinePlace)
        ? item.geotaggedPhotos
        : (item is TimelinePath ? item.geotaggedPhotos : <PhotoEntry>[]);
    if (geotagged.isEmpty) return;

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final double tz = settings.geotagTimezone.toDouble();
    final dateInfo = _currentDateInfo(appState);
    final points = appState.activePaths[dateInfo.filePath] ?? [];
    if (points.isEmpty) return;

    int updatedCount = 0;
    setState(() {
      for (final photo in geotagged) {
        if (photo.dateTaken == null) continue;
        final LatLng? interpolated =
            _interpolatePositionAtTime(photo.dateTaken!, points, tz);
        if (interpolated != null) {
          photo.gpsLatLng = interpolated;
          photo.interpolatedLatLng = null;
          photo.addedToTimeline = true;
          updatedCount++;
        }
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text('Updated $updatedCount photo geotag(s) to match timeline track'),
      backgroundColor: Colors.teal,
      duration: const Duration(seconds: 2),
    ));

    _assignPhotosToTimelineItems(points, tz);
  }

  /// Modify Timeline -> Adjust timeline track points to pass through photo GPS locations
  Future<void> _modifyTimelineFromPhotosInItem(TimelineItem item) async {
    final geotagged = (item is TimelinePlace)
        ? item.geotaggedPhotos
        : (item is TimelinePath ? item.geotaggedPhotos : <PhotoEntry>[]);
    if (geotagged.isEmpty) return;

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final double tz = settings.geotagTimezone.toDouble();
    final dateInfo = _currentDateInfo(appState);

    List<LocationPoint> points = dateInfo.filePath.isNotEmpty
        ? await LocationManager.loadLocationFile(dateInfo.filePath)
        : [];

    int modifiedPointsCount = 0;
    for (final photo in geotagged) {
      if (photo.gpsLatLng == null || photo.dateTaken == null) continue;
      final photoUtc =
          photo.dateTaken!.subtract(Duration(minutes: (tz * 60).toInt()));

      int nearestIdx = -1;
      int minDiffMs = 60000; // 60s window
      for (int i = 0; i < points.length; i++) {
        final diff =
            points[i].timestamp.difference(photoUtc).inMilliseconds.abs();
        if (diff < minDiffMs) {
          minDiffMs = diff;
          nearestIdx = i;
        }
      }

      if (nearestIdx != -1) {
        points[nearestIdx] = LocationPoint(
          latitude: photo.gpsLatLng!.latitude,
          longitude: photo.gpsLatLng!.longitude,
          timestamp: points[nearestIdx].timestamp,
          elevation: points[nearestIdx].elevation,
          activityType: points[nearestIdx].activityType,
        );
      } else {
        points.add(LocationPoint(
          latitude: photo.gpsLatLng!.latitude,
          longitude: photo.gpsLatLng!.longitude,
          timestamp: photoUtc,
        ));
      }
      photo.addedToTimeline = true;
      modifiedPointsCount++;
    }

    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await appState.saveListPoints(dateInfo, points);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Updated timeline track with $modifiedPointsCount photo location(s)'),
      backgroundColor: Colors.indigo,
      duration: const Duration(seconds: 2),
    ));

    _loadPointsForSelectedDate();
  }

  Widget _buildSquarePhotoTile(PhotoEntry photo) {
    final isSel = _selectedPhoto == photo || _selectedPhotoSet.contains(photo);
    final isGeo = photo.hasExifGps;
    final Color borderColor = isSel
        ? Colors.amber
        : (isGeo ? Colors.white70 : Colors.lightBlue.shade200);

    return GestureDetector(
      onTap: () => setState(() {
        if (HardwareKeyboard.instance.isControlPressed) {
          if (_selectedPhotoSet.contains(photo)) {
            _selectedPhotoSet.remove(photo);
          } else {
            _selectedPhotoSet.add(photo);
          }
        } else {
          _selectedPhotoSet.clear();
          _selectedPhoto = (_selectedPhoto == photo) ? null : photo;
        }
      }),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor, width: isSel ? 2.0 : 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6.5),
          child: Image.file(
            photo.file,
            width: 38,
            height: 38,
            fit: BoxFit.cover,
            cacheWidth: 80,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey.shade800,
              child: const Icon(Icons.broken_image,
                  size: 14, color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeotagAllButton(TimelineItem item) {
    return Material(
      color: Colors.teal,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _geotagAllInItem(item),
        child: Container(
          width: 80,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.pin_drop, size: 14, color: Colors.white),
              SizedBox(width: 3),
              Expanded(
                child: Text(
                  'Geotag All',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModifyGeotagButton(TimelineItem item) {
    return Tooltip(
      message: 'Chỉnh vị trí ảnh cho đúng với đường Timeline',
      child: Material(
        color: Colors.teal.shade700,
        borderRadius: BorderRadius.circular(20),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _modifyGeotagsFromTimelineInItem(item),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.edit_location_alt, size: 14, color: Colors.white),
                SizedBox(width: 3),
                Text(
                  'Modify Geotag',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModifyTimelineButton(TimelineItem item) {
    return Tooltip(
      message: 'Chỉnh đường Timeline cho đi qua đúng vị trí chụp ảnh',
      child: Material(
        color: Colors.indigo.shade600,
        borderRadius: BorderRadius.circular(20),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _modifyTimelineFromPhotosInItem(item),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_location_alt, size: 14, color: Colors.white),
                SizedBox(width: 3),
                Text(
                  'Modify Timeline',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandPhotoButton(int itemIndex, bool isExpanded) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() {
          if (isExpanded) {
            _expandedPhotoGrids.remove(itemIndex);
          } else {
            _expandedPhotoGrids.add(itemIndex);
          }
        }),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: Icon(
            isExpanded ? Icons.expand_less : Icons.grid_view,
            size: 16,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelinePhotoRows(
      BuildContext context, TimelineItem item, int itemIndex) {
    final geotagged = (item is TimelinePlace)
        ? item.geotaggedPhotos
        : (item is TimelinePath ? item.geotaggedPhotos : <PhotoEntry>[]);
    final ungeotagged = (item is TimelinePlace)
        ? item.ungeotaggedPhotos
        : (item is TimelinePath ? item.ungeotaggedPhotos : <PhotoEntry>[]);

    if (geotagged.isEmpty && ungeotagged.isEmpty) {
      return const SizedBox.shrink();
    }

    final isExpanded = _expandedPhotoGrids.contains(itemIndex);
    final allPhotos = [...geotagged, ...ungeotagged];
    final hasGeotagged = geotagged.isNotEmpty;
    final hasUngeotagged = ungeotagged.isNotEmpty;

    final double availableWidth = max(80.0, _sidebarWidth - 118.0);

    const double photoTileW = 38.0;
    const double geotagBtnW = 80.0;
    const double modGeotagBtnW = 96.0;
    const double modTimelineBtnW = 102.0;
    const double expandBtnW = 38.0;
    const double gap = 4.0;

    // Calculate total width required if everything is displayed in 1 row
    double totalRequiredWidth = allPhotos.length * (photoTileW + gap);
    if (hasUngeotagged) {
      totalRequiredWidth += (geotagBtnW + gap);
    }
    if (hasGeotagged) {
      totalRequiredWidth += (modGeotagBtnW + gap) + (modTimelineBtnW + gap);
    }
    if (totalRequiredWidth > 0) {
      totalRequiredWidth -= gap; // remove trailing gap
    }

    // Check if items exceed available width
    final bool overflows = totalRequiredWidth > availableWidth;

    Widget body;

    if (isExpanded) {
      // Expanded view: Wrap grid with Collapse button
      body = Wrap(
        spacing: gap,
        runSpacing: gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...allPhotos.map(_buildSquarePhotoTile),
          if (hasUngeotagged) _buildGeotagAllButton(item),
          if (hasGeotagged) ...[
            _buildModifyGeotagButton(item),
            _buildModifyTimelineButton(item),
          ],
          _buildExpandPhotoButton(itemIndex, true),
        ],
      );
    } else if (!overflows) {
      // Collapsed view but everything fits! No expand button needed.
      body = Wrap(
        spacing: gap,
        runSpacing: gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...allPhotos.map(_buildSquarePhotoTile),
          if (hasUngeotagged) _buildGeotagAllButton(item),
          if (hasGeotagged) ...[
            _buildModifyGeotagButton(item),
            _buildModifyTimelineButton(item),
          ],
        ],
      );
    } else {
      // Collapsed view with overflow: calculate visible photos/buttons
      final double widthForContent = availableWidth - (expandBtnW + gap);
      double currentW = 0.0;
      final List<Widget> visibleWidgets = [];

      for (int i = 0; i < allPhotos.length; i++) {
        final needed = photoTileW + (visibleWidgets.isEmpty ? 0 : gap);
        if (currentW + needed <= widthForContent) {
          visibleWidgets.add(_buildSquarePhotoTile(allPhotos[i]));
          currentW += needed;
        } else {
          break;
        }
      }

      // Check if Geotag All button fits in remaining space
      if (hasUngeotagged) {
        final neededGeo = geotagBtnW + (visibleWidgets.isEmpty ? 0 : gap);
        if (currentW + neededGeo <= widthForContent) {
          visibleWidgets.add(_buildGeotagAllButton(item));
          currentW += neededGeo;
        }
      }

      // Check if Modify Geotag & Modify Timeline buttons fit in remaining space
      if (hasGeotagged) {
        final neededModGeo = modGeotagBtnW + (visibleWidgets.isEmpty ? 0 : gap);
        if (currentW + neededModGeo <= widthForContent) {
          visibleWidgets.add(_buildModifyGeotagButton(item));
          currentW += neededModGeo;

          final neededModTime = modTimelineBtnW + gap;
          if (currentW + neededModTime <= widthForContent) {
            visibleWidgets.add(_buildModifyTimelineButton(item));
          }
        }
      }

      // Use Wrap instead of Row to eliminate overflow errors
      body = Wrap(
        spacing: gap,
        runSpacing: gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...visibleWidgets,
          _buildExpandPhotoButton(itemIndex, false),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: body,
    );
  }

  /// Promotes the interpolated position of [photo] to its GPS coordinate
  /// (in memory), moving it from ungeotagged → geotagged.
  void _applyInterpolatedGeotag(PhotoEntry photo) {
    final loc = photo.interpolatedLatLng;
    if (loc == null) return;
    setState(() {
      photo.gpsLatLng = loc;
      photo.interpolatedLatLng = null;
      photo.addedToTimeline = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Geotag applied: "${photo.filename}" '
          '(${loc.latitude.toStringAsFixed(5)}, '
          '${loc.longitude.toStringAsFixed(5)})'),
      backgroundColor: Colors.teal,
      duration: const Duration(seconds: 2),
    ));
    // Rebuild so photo moves from ungeotagged row → geotagged row
    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final pts = appState.activePaths[_currentDateInfo(appState).filePath] ?? [];
    _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Map animation & fit — _animatedMapMove, _fitBounds
  // ─────────────────────────────────────────────────────────────────────────

  void _animatedMapMove(LatLng destCenter, double destZoom) {
    _mapAnimationController?.stop();
    _mapAnimationController?.dispose();

    final controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _mapAnimationController = controller;

    final LatLng startCenter = _mapController.camera.center;
    final double startZoom = _mapController.camera.zoom;

    final Animation<double> animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );

    controller.addListener(() {
      final double t = animation.value;
      final double lat = startCenter.latitude +
          (destCenter.latitude - startCenter.latitude) * t;
      final double lng = startCenter.longitude +
          (destCenter.longitude - startCenter.longitude) * t;
      final double zoom = startZoom + (destZoom - startZoom) * t;

      _mapController.move(LatLng(lat, lng), zoom);
    });

    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        controller.dispose();
        if (_mapAnimationController == controller) {
          _mapAnimationController = null;
        }
      }
    });

    controller.forward();
  }

  void _animatedFitBounds(LatLngBounds bounds,
      {EdgeInsets padding = const EdgeInsets.all(40)}) {
    try {
      final cameraFit = CameraFit.bounds(bounds: bounds, padding: padding);
      final targetCamera = cameraFit.fit(_mapController.camera);
      _animatedMapMove(targetCamera.center, targetCamera.zoom);
    } catch (_) {
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: padding),
      );
    }
  }

  void _fitBounds() {
    final appState = context.read<AppStateProvider>();
    final paths = appState.activePaths;
    if (paths.isEmpty) return;

    final allPoints =
        paths.values.expand((points) => points.map((p) => p.latLng)).toList();
    if (allPoints.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(allPoints);

    _animatedFitBounds(bounds, padding: const EdgeInsets.all(50.0));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Pointer / drag interactions — hover, pointer down/move/up
  // ─────────────────────────────────────────────────────────────────────────

  List<LocationPoint> _getActiveHoverPoints(
      List<LocationPoint> dayPoints, double timeOffset) {
    if (_selectedTimelineItemIndex != null) {
      final items =
          _timelineItemsWithPhotos ?? _clusterTimeline(dayPoints, timeOffset);
      if (_selectedTimelineItemIndex! < items.length) {
        final selectedItem = items[_selectedTimelineItemIndex!];

        if (selectedItem is TimelinePath) {
          return selectedItem.points;
        } else if (selectedItem is TimelinePlace) {
          final List<LocationPoint> activePoints = [];

          // Incoming neighbor path
          if (_selectedTimelineItemIndex! - 1 >= 0) {
            final incoming = items[_selectedTimelineItemIndex! - 1];
            if (incoming is TimelinePath) {
              activePoints.addAll(incoming.points);
            }
          }
          // Outgoing neighbor path
          if (_selectedTimelineItemIndex! + 1 < items.length) {
            final outgoing = items[_selectedTimelineItemIndex! + 1];
            if (outgoing is TimelinePath) {
              activePoints.addAll(outgoing.points);
            }
          }
          return activePoints;
        }
      }
    }

    return dayPoints;
  }

  void _handleHover(PointerHoverEvent event, LatLng point) {
    final appState = context.read<AppStateProvider>();
    if (!appState.isEditing) {
      // Non-edit mode: hover over existing tracks
      final currentDayInfo = appState.allDates.firstWhere(
        (d) =>
            _selectedDate != null &&
            d.date.year == _selectedDate!.year &&
            d.date.month == _selectedDate!.month &&
            d.date.day == _selectedDate!.day,
        orElse: () => DateInfo(
          date: _selectedDate ?? DateTime.now(),
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );

      final settings = context.read<SettingsProvider>();
      final timeOffset = settings.geotagTimezone.toDouble();
      final rawDayPoints = appState.activePaths[currentDayInfo.filePath] ?? [];

      // Detect hover over any TimelineItem (Path or Place)
      double currentZoom = 13.0;
      try {
        currentZoom = _mapController.camera.zoom;
      } catch (_) {}

      final double pathHoverDistThreshold = 0.035 / pow(2, currentZoom - 10);
      final double pathHoverDistThresholdSq =
          pathHoverDistThreshold * pathHoverDistThreshold;

      // Larger buffer area for Places (~600m+)
      final double placeHoverDistThreshold = 0.065 / pow(2, currentZoom - 10);
      final double placeHoverDistThresholdSq =
          placeHoverDistThreshold * placeHoverDistThreshold;

      final timelineItems = _clusterTimeline(rawDayPoints, timeOffset);
      int? foundHoverIdx;
      double minHoverDistSq = double.infinity;

      // 1. Check Places first with the larger Place buffer
      for (int i = 0; i < timelineItems.length; i++) {
        final item = timelineItems[i];
        if (item is TimelinePlace) {
          final dy = item.center.latitude - point.latitude;
          final dx = item.center.longitude - point.longitude;
          final distSq = dy * dy + dx * dx;
          if (distSq < minHoverDistSq && distSq < placeHoverDistThresholdSq) {
            minHoverDistSq = distSq;
            foundHoverIdx = i;
          }
        }
      }

      // 2. If no Place was hovered, check Paths with standard buffer
      if (foundHoverIdx == null) {
        for (int i = 0; i < timelineItems.length; i++) {
          final item = timelineItems[i];
          if (item is TimelinePath && item.points.isNotEmpty) {
            final proj = _getNearestProjection(point, item.points);
            if (proj != null &&
                proj.distance < minHoverDistSq &&
                proj.distance < pathHoverDistThresholdSq) {
              minHoverDistSq = proj.distance;
              foundHoverIdx = i;
            }
          }
        }
      }

      if (_hoveredTimelineItemIndex != foundHoverIdx) {
        setState(() {
          _hoveredTimelineItemIndex = foundHoverIdx;
        });
      }

      // If a Place is currently hovered, suppress Path hover points/dots so only the Place is targeted
      final bool isPlaceHovered = (foundHoverIdx != null &&
          foundHoverIdx < timelineItems.length &&
          timelineItems[foundHoverIdx] is TimelinePlace);

      if (isPlaceHovered) {
        if (_hoveredLatLng != null) {
          setState(() {
            _hoveredPoint = null;
            _hoveredColor = null;
            _hoveredLatLng = null;
          });
        }
        return;
      }

      final points = _getActiveHoverPoints(rawDayPoints, timeOffset);
      if (points.isEmpty) {
        if (_hoveredLatLng != null) {
          setState(() {
            _hoveredPoint = null;
            _hoveredColor = null;
            _hoveredLatLng = null;
          });
        }
        return;
      }

      if (points.length == 1) {
        final p = points.first;
        setState(() {
          _hoveredPoint = p;
          _hoveredColor = Colors.white;
          _hoveredLatLng = p.latLng;
        });
        return;
      }

      final projection = _getNearestProjection(point, points);
      if (projection == null) return;

      // Hover radius threshold (~400m)
      final double hoverThreshold = 0.035 / pow(2, currentZoom - 10);
      final double hoverThresholdSq = hoverThreshold * hoverThreshold;

      if (projection.distance < hoverThresholdSq) {
        // Find segment points
        final int startIdx = projection.insertIndex - 1;
        final int endIdx = projection.insertIndex;
        final startPt = points[startIdx];
        final endPt = points[endIdx];

        // Snapping check to actual coordinate points
        final double snapThreshold = 0.015 / pow(2, currentZoom - 10);
        final double snapThresholdSq = snapThreshold * snapThreshold;

        final dLatStart = startPt.latitude - point.latitude;
        final dLonStart = startPt.longitude - point.longitude;
        final distStartSq = dLatStart * dLatStart + dLonStart * dLonStart;

        final dLatEnd = endPt.latitude - point.latitude;
        final dLonEnd = endPt.longitude - point.longitude;
        final distEndSq = dLatEnd * dLatEnd + dLonEnd * dLonEnd;

        LatLng finalPoint;
        DateTime finalTime;
        bool isSnapped = false;

        if (distStartSq < snapThresholdSq || distEndSq < snapThresholdSq) {
          // Snap to the closer coordinate point
          isSnapped = true;
          if (distStartSq <= distEndSq) {
            finalPoint = startPt.latLng;
            finalTime = startPt.timestamp;
          } else {
            finalPoint = endPt.latLng;
            finalTime = endPt.timestamp;
          }
        } else {
          // Move smoothly along the line segment path
          finalPoint = projection.point;
          final gap = endPt.timestamp.difference(startPt.timestamp);
          finalTime = startPt.timestamp.add(gap * projection.t);
        }

        final newHovered = LocationPoint(
          latitude: finalPoint.latitude,
          longitude: finalPoint.longitude,
          timestamp: finalTime,
        );

        if (_hoveredPoint?.latitude != finalPoint.latitude ||
            _hoveredPoint?.longitude != finalPoint.longitude ||
            _hoveredPoint?.timestamp != finalTime) {
          setState(() {
            _hoveredPoint = newHovered;
            _hoveredColor = isSnapped ? Colors.white : Colors.purple;
            _hoveredLatLng = finalPoint;
          });
        }
      } else {
        if (_hoveredLatLng != null) {
          setState(() {
            _hoveredPoint = null;
            _hoveredColor = null;
            _hoveredLatLng = null;
          });
        }
      }
      return;
    }

    // Edit mode: hover over the editing polyline
    if (_isDraggingPoint) {
      if (_hoveredLatLng != null) {
        setState(() {
          _hoveredLatLng = null;
          _hoveredProjection = null;
        });
      }
      return;
    }

    final editingPoints = appState.editingPoints;
    if (editingPoints.length < 2) return;

    final projection = _getNearestProjection(point, editingPoints);
    if (projection == null) return;

    double currentZoom = 13.0;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {}

    final snapThreshold = 0.02 / pow(2, currentZoom - 10);
    final snapThresholdSq = snapThreshold * snapThreshold;

    if (projection.distance < snapThresholdSq) {
      setState(() {
        _hoveredLatLng = projection.point;
        _hoveredProjection = projection;
      });
    } else {
      if (_hoveredLatLng != null) {
        setState(() {
          _hoveredLatLng = null;
          _hoveredProjection = null;
        });
      }
    }
  }

  // ── Save-to-disk with sync indicator ────────────────────────────────────
  void _saveWithIndicator(AppStateProvider appState, DateInfo dateInfo,
      List<LocationPoint> points) {
    _savingCount++;
    if (mounted) setState(() => _isSaving = true);
    appState.saveListPoints(dateInfo, points).whenComplete(() {
      _savingCount = (_savingCount - 1).clamp(0, 999);
      if (mounted && _savingCount == 0) setState(() => _isSaving = false);
    });
  }

  void _handlePointerDown(PointerDownEvent event, LatLng tapLatLng) {
    final appState = context.read<AppStateProvider>();

    double currentZoom = 13.0;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {}

    // ── Left click on hovered timeline item shifts focus to it ────────────────
    if (event.buttons != kSecondaryButton &&
        _hoveredTimelineItemIndex != null) {
      setState(() {
        _selectedTimelineItemIndex = _hoveredTimelineItemIndex;
      });
    }

    // ── Place marker dragging check ──────────────────────────────────────────
    if (event.buttons != kSecondaryButton &&
        _selectedTimelineItemIndex != null &&
        !appState.isEditing) {
      final currentDayInfo = appState.allDates.firstWhere(
        (d) =>
            _selectedDate != null &&
            d.date.year == _selectedDate!.year &&
            d.date.month == _selectedDate!.month &&
            d.date.day == _selectedDate!.day,
        orElse: () => DateInfo(
          date: _selectedDate ?? DateTime.now(),
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );
      final rawDayPoints = appState.activePaths[currentDayInfo.filePath] ?? [];
      final settings = context.read<SettingsProvider>();
      final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
      final canDragOrEdit = !settings.requireShiftToDrag || isShiftPressed;
      final timeOffset = settings.geotagTimezone.toDouble();
      final timelineItems = _clusterTimeline(rawDayPoints, timeOffset);

      if (canDragOrEdit && _selectedTimelineItemIndex! < timelineItems.length) {
        final item = timelineItems[_selectedTimelineItemIndex!];
        if (item is TimelinePlace) {
          final double threshold = 0.065 / pow(2, currentZoom - 10);
          final double thresholdSq = threshold * threshold;
          final dy = item.center.latitude - tapLatLng.latitude;
          final dx = item.center.longitude - tapLatLng.longitude;
          if (dy * dy + dx * dx < thresholdSq) {
            setState(() {
              _isDraggingPlace = true;
              _draggingPlaceIndex = _selectedTimelineItemIndex;
              _draggingPlaceStartLatLng = tapLatLng;
              _draggedPlaceCurrentLatLng = item.center;
            });
            return;
          }
        }
      }
    }

    final settings = context.read<SettingsProvider>();
    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
    final canDragOrEdit = !settings.requireShiftToDrag || isShiftPressed;

    // ── Right click: Start multi-point selection drag box ────────────────────
    if (event.buttons == kSecondaryButton) {
      setState(() {
        _isRightClickSelecting = true;
        _rightClickStartLatLng = tapLatLng;
        _rightClickCurrentLatLng = tapLatLng;
      });
      return;
    }
    final photoThreshold = 0.025 / pow(2, currentZoom - 10);
    final photoThresholdSq = photoThreshold * photoThreshold;
    PhotoEntry? hitPhoto;
    double hitPhotoDistSq = double.infinity;
    for (final photo in _photos) {
      final loc = photo.assignedLatLng;
      if (loc == null) continue;
      final dLat = loc.latitude - tapLatLng.latitude;
      final dLon = loc.longitude - tapLatLng.longitude;
      final distSq = dLat * dLat + dLon * dLon;
      if (distSq < hitPhotoDistSq && distSq < photoThresholdSq) {
        hitPhotoDistSq = distSq;
        hitPhoto = photo;
      }
    }
    if (canDragOrEdit && hitPhoto != null) {
      setState(() {
        _draggingPhoto = hitPhoto;
        _isDraggingPhoto = true;
        _selectedPhoto = hitPhoto;
      });
      return; // consume event — don't edit route
    }

    // Check if clicked near the hover dot
    if (canDragOrEdit && _hoveredLatLng != null && _hoveredPoint != null) {
      final double hoverThreshold = 0.025 / pow(2, currentZoom - 10);
      final double hoverThresholdSq = hoverThreshold * hoverThreshold;

      final dLat = _hoveredLatLng!.latitude - tapLatLng.latitude;
      final dLon = _hoveredLatLng!.longitude - tapLatLng.longitude;
      final distSq = dLat * dLat + dLon * dLon;

      if (distSq < hoverThresholdSq) {
        final currentDayInfo = appState.allDates.firstWhere(
          (d) =>
              _selectedDate != null &&
              d.date.year == _selectedDate!.year &&
              d.date.month == _selectedDate!.month &&
              d.date.day == _selectedDate!.day,
          orElse: () => DateInfo(
            date: _selectedDate ?? DateTime.now(),
            pointCount: 0,
            filePath: '',
            distance: 0.0,
            state: 'original',
            source: 'merge',
            hasTimelineBackup: false,
            hasGpxBackup: false,
          ),
        );
        final allPoints = appState.isEditing
            ? appState.editingPoints
            : (appState.activePaths[currentDayInfo.filePath] ?? []);

        final timeOffset = settings.geotagTimezone.toDouble();
        final points = appState.isEditing
            ? allPoints
            : _getActiveHoverPoints(allPoints, timeOffset);

        final projection = _getNearestProjection(tapLatLng, points);
        if (projection != null) {
          int globalInsertIndex = projection.insertIndex;
          if (!appState.isEditing &&
              points.isNotEmpty &&
              projection.insertIndex > 0) {
            final prevPt = points[projection.insertIndex - 1];
            final globalPrevIdx = allPoints.indexOf(prevPt);
            if (globalPrevIdx >= 0) {
              globalInsertIndex = globalPrevIdx + 1;
            }
          }

          TimelinePath? targetSegment;
          if (!appState.isEditing && _timelineItemsWithPhotos != null) {
            final hoverTime = _hoveredPoint!.timestamp;
            for (final item in _timelineItemsWithPhotos!) {
              if (item is TimelinePath) {
                if ((hoverTime.isAfter(item.startTime) ||
                        hoverTime.isAtSameMomentAs(item.startTime)) &&
                    (hoverTime.isBefore(item.endTime) ||
                        hoverTime.isAtSameMomentAs(item.endTime))) {
                  targetSegment = item;
                  break;
                }
              }
            }
          }

          setState(() {
            _isDraggingHoverDot = true;
            _draggedHoverDotTime = _hoveredPoint!.timestamp;
            _draggedHoverDotInsertIndex = globalInsertIndex;
            _draggedHoverDotCurrentLatLng = _hoveredLatLng;
            _draggedHoverDotSegment = targetSegment;
          });
          return;
        }
      }
    }

    if (!appState.isEditing || !canDragOrEdit) return;

    final touchThreshold = 0.015 / pow(2, currentZoom - 10);
    final touchThresholdSq = touchThreshold * touchThreshold;

    final editingPoints = appState.editingPoints;

    int? clickedIndex;
    double minDistanceSq = double.infinity;

    for (int i = 0; i < editingPoints.length; i++) {
      final pt = editingPoints[i];
      final dLat = pt.latitude - tapLatLng.latitude;
      final dLon = pt.longitude - tapLatLng.longitude;
      final distSq = dLat * dLat + dLon * dLon;

      if (distSq < minDistanceSq && distSq < touchThresholdSq) {
        minDistanceSq = distSq;
        clickedIndex = i;
      }
    }

    if (clickedIndex != null) {
      setState(() {
        _selectedPointIndex = clickedIndex;
        _isDraggingPoint = true;
        _hoveredLatLng = null;
        _hoveredProjection = null;
      });
      return;
    }

    if (_hoveredProjection != null) {
      final proj = _hoveredProjection!;
      appState.insertPoint(proj.insertIndex, proj.point, proj.t);
      setState(() {
        _selectedPointIndex = proj.insertIndex;
        _isDraggingPoint = true;
        _hoveredLatLng = null;
        _hoveredProjection = null;
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event, LatLng moveLatLng) {
    if (_isDraggingPlace &&
        _draggingPlaceStartLatLng != null &&
        _draggingPlaceIndex != null) {
      final appState = context.read<AppStateProvider>();
      final currentDayInfo = appState.allDates.firstWhere(
        (d) =>
            _selectedDate != null &&
            d.date.year == _selectedDate!.year &&
            d.date.month == _selectedDate!.month &&
            d.date.day == _selectedDate!.day,
        orElse: () => DateInfo(
          date: _selectedDate ?? DateTime.now(),
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );
      final rawDayPoints = appState.activePaths[currentDayInfo.filePath] ?? [];
      final settings = context.read<SettingsProvider>();
      final timeOffset = settings.geotagTimezone.toDouble();
      final timelineItems = _clusterTimeline(rawDayPoints, timeOffset);

      if (_draggingPlaceIndex! < timelineItems.length) {
        final item = timelineItems[_draggingPlaceIndex!];
        if (item is TimelinePlace) {
          final dLat =
              moveLatLng.latitude - _draggingPlaceStartLatLng!.latitude;
          final dLng =
              moveLatLng.longitude - _draggingPlaceStartLatLng!.longitude;

          setState(() {
            _draggedPlaceCurrentLatLng = LatLng(
                item.center.latitude + dLat, item.center.longitude + dLng);
          });
        }
      }
      return;
    }

    if (_isRightClickSelecting) {
      setState(() {
        _rightClickCurrentLatLng = moveLatLng;
      });
      return;
    }

    if (_isDraggingHoverDot) {
      setState(() {
        _draggedHoverDotCurrentLatLng = moveLatLng;
        _hoveredLatLng = moveLatLng;
        _hoveredPoint = LocationPoint(
          latitude: moveLatLng.latitude,
          longitude: moveLatLng.longitude,
          timestamp: _draggedHoverDotTime!,
        );
      });
      return;
    }

    if (_isDraggingPhoto && _draggingPhoto != null) {
      final oldLoc = _draggingPhoto!.assignedLatLng;
      if (oldLoc != null) {
        final dLat = moveLatLng.latitude - oldLoc.latitude;
        final dLng = moveLatLng.longitude - oldLoc.longitude;

        setState(() {
          // Update main dragging photo
          if (_draggingPhoto!.gpsLatLng != null) {
            _draggingPhoto!.gpsLatLng = moveLatLng;
          } else {
            _draggingPhoto!.interpolatedLatLng = moveLatLng;
          }

          // If multi-selected set contains the dragging photo, move all others too
          if (_selectedPhotoSet.contains(_draggingPhoto)) {
            for (final photo in _selectedPhotoSet) {
              if (photo == _draggingPhoto) continue;
              final curLoc = photo.assignedLatLng;
              if (curLoc == null) continue;
              final moved =
                  LatLng(curLoc.latitude + dLat, curLoc.longitude + dLng);
              if (photo.gpsLatLng != null) {
                photo.gpsLatLng = moved;
              } else {
                photo.interpolatedLatLng = moved;
              }
            }
          }
        });
      }
      return;
    }

    if (_isDraggingPoint && _selectedPointIndex != null) {
      final appState = context.read<AppStateProvider>();
      try {
        appState.updatePointCoordinate(_selectedPointIndex!, moveLatLng);
      } catch (_) {}
    }
  }

  void _handlePointerUp(PointerUpEvent event, LatLng upLatLng) {
    if (_isDraggingPlace &&
        _draggingPlaceStartLatLng != null &&
        _draggingPlaceIndex != null) {
      final appState = context.read<AppStateProvider>();
      final currentDayInfo = appState.allDates.firstWhere(
        (d) =>
            _selectedDate != null &&
            d.date.year == _selectedDate!.year &&
            d.date.month == _selectedDate!.month &&
            d.date.day == _selectedDate!.day,
        orElse: () => DateInfo(
          date: _selectedDate ?? DateTime.now(),
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );
      final dayPoints = appState.activePaths[currentDayInfo.filePath] ?? [];
      final settings = context.read<SettingsProvider>();
      final timeOffset = settings.geotagTimezone.toDouble();
      final timelineItems = _clusterTimeline(dayPoints, timeOffset);

      if (_draggingPlaceIndex! < timelineItems.length) {
        final item = timelineItems[_draggingPlaceIndex!];
        if (item is TimelinePlace && item.points.isNotEmpty) {
          final dLat = upLatLng.latitude - _draggingPlaceStartLatLng!.latitude;
          final dLng =
              upLatLng.longitude - _draggingPlaceStartLatLng!.longitude;

          // Back up adjacent roads for session Undo
          if (_draggingPlaceIndex! - 1 >= 0 &&
              timelineItems[_draggingPlaceIndex! - 1] is TimelinePath) {
            final prevPath =
                timelineItems[_draggingPlaceIndex! - 1] as TimelinePath;
            final key = _getSegmentKey(prevPath.startTime, prevPath.endTime);
            _unsnappedSegmentBackups[key] =
                List<LocationPoint>.from(prevPath.points);
          }
          if (_draggingPlaceIndex! + 1 < timelineItems.length &&
              timelineItems[_draggingPlaceIndex! + 1] is TimelinePath) {
            final nextPath =
                timelineItems[_draggingPlaceIndex! + 1] as TimelinePath;
            final key = _getSegmentKey(nextPath.startTime, nextPath.endTime);
            _unsnappedSegmentBackups[key] =
                List<LocationPoint>.from(nextPath.points);
          }

          final updated = List<LocationPoint>.from(dayPoints);
          final placeStart =
              item.startTime.subtract(const Duration(seconds: 1));
          final placeEnd = item.endTime.add(const Duration(seconds: 1));

          DateTime? prevPathLastTime;
          DateTime? nextPathFirstTime;

          if (_draggingPlaceIndex! - 1 >= 0 &&
              timelineItems[_draggingPlaceIndex! - 1] is TimelinePath) {
            final prevPath =
                timelineItems[_draggingPlaceIndex! - 1] as TimelinePath;
            if (prevPath.points.isNotEmpty) {
              prevPathLastTime = prevPath.points.last.timestamp;
            }
          }

          if (_draggingPlaceIndex! + 1 < timelineItems.length &&
              timelineItems[_draggingPlaceIndex! + 1] is TimelinePath) {
            final nextPath =
                timelineItems[_draggingPlaceIndex! + 1] as TimelinePath;
            if (nextPath.points.isNotEmpty) {
              nextPathFirstTime = nextPath.points.first.timestamp;
            }
          }

          for (int i = 0; i < updated.length; i++) {
            final p = updated[i];
            final bool isPlacePt = !p.timestamp.isBefore(placeStart) &&
                !p.timestamp.isAfter(placeEnd);
            final bool isIncomingEndPt = (prevPathLastTime != null &&
                p.timestamp.millisecondsSinceEpoch ==
                    prevPathLastTime.millisecondsSinceEpoch);
            final bool isOutgoingStartPt = (nextPathFirstTime != null &&
                p.timestamp.millisecondsSinceEpoch ==
                    nextPathFirstTime.millisecondsSinceEpoch);

            if (isPlacePt || isIncomingEndPt || isOutgoingStartPt) {
              updated[i] = LocationPoint(
                latitude: p.latitude + dLat,
                longitude: p.longitude + dLng,
                timestamp: p.timestamp,
              );
            }
          }

          // Instant repaint with 0ms latency, then persist to disk async
          appState.updateActivePathInMemory(currentDayInfo, updated);
          _saveWithIndicator(appState, currentDayInfo, updated);
        }
      }

      setState(() {
        _isDraggingPlace = false;
        _draggingPlaceIndex = null;
        _draggingPlaceStartLatLng = null;
        _draggedPlaceCurrentLatLng = null;
      });
      return;
    }

    if (_isRightClickSelecting) {
      final appState = context.read<AppStateProvider>();
      final currentDayInfo = appState.allDates.firstWhere(
        (d) =>
            _selectedDate != null &&
            d.date.year == _selectedDate!.year &&
            d.date.month == _selectedDate!.month &&
            d.date.day == _selectedDate!.day,
        orElse: () => DateInfo(
          date: _selectedDate ?? DateTime.now(),
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );

      final allPoints = appState.isEditing
          ? appState.editingPoints
          : (appState.activePaths[currentDayInfo.filePath] ?? []);

      final settings = context.read<SettingsProvider>();
      final timeOffset = settings.geotagTimezone.toDouble();
      final activePts = appState.isEditing
          ? allPoints
          : _getActiveHoverPoints(allPoints, timeOffset);

      if (_rightClickStartLatLng != null && _rightClickCurrentLatLng != null) {
        final start = _rightClickStartLatLng!;
        final end = _rightClickCurrentLatLng!;

        double currentZoom = 13.0;
        try {
          currentZoom = _mapController.camera.zoom;
        } catch (_) {}

        final double dLat = (start.latitude - end.latitude).abs();
        final double dLng = (start.longitude - end.longitude).abs();

        final List<LocationPoint> pointsToDelete = [];

        if (dLat < 0.0001 && dLng < 0.0001) {
          // Single right-click tap (~400m threshold)
          final double deleteThreshold = 0.035 / pow(2, currentZoom - 10);
          final double deleteThresholdSq = deleteThreshold * deleteThreshold;

          LocationPoint? hitPt;
          double minDistSq = double.infinity;
          for (final p in activePts) {
            final dy = p.latitude - end.latitude;
            final dx = p.longitude - end.longitude;
            final distSq = dy * dy + dx * dx;
            if (distSq < minDistSq && distSq < deleteThresholdSq) {
              minDistSq = distSq;
              hitPt = p;
            }
          }
          if (hitPt != null) {
            pointsToDelete.add(hitPt);
          }
        } else {
          // Drag selection box
          final minLat = min(start.latitude, end.latitude);
          final maxLat = max(start.latitude, end.latitude);
          final minLng = min(start.longitude, end.longitude);
          final maxLng = max(start.longitude, end.longitude);

          for (final p in activePts) {
            if (p.latitude >= minLat &&
                p.latitude <= maxLat &&
                p.longitude >= minLng &&
                p.longitude <= maxLng) {
              pointsToDelete.add(p);
            }
          }
        }

        if (pointsToDelete.isNotEmpty) {
          if (appState.isEditing) {
            appState.editingPoints
                .removeWhere((p) => pointsToDelete.contains(p));
          } else {
            final timelineItems = _clusterTimeline(allPoints, timeOffset);
            for (final item in timelineItems) {
              if (item is TimelinePath &&
                  item.points.any((p) => pointsToDelete.contains(p))) {
                final key = _getSegmentKey(item.startTime, item.endTime);
                _unsnappedSegmentBackups[key] =
                    List<LocationPoint>.from(item.points);
              }
            }

            final updated = List<LocationPoint>.from(allPoints);
            updated.removeWhere((p) => pointsToDelete.any((del) =>
                del == p ||
                (del.latitude == p.latitude &&
                    del.longitude == p.longitude &&
                    del.timestamp == p.timestamp)));
            appState.updateActivePathInMemory(currentDayInfo, updated);
            _saveWithIndicator(appState, currentDayInfo, updated);
          }

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    '${pointsToDelete.length} point${pointsToDelete.length > 1 ? 's' : ''} deleted.'),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        }
      }

      setState(() {
        _isRightClickSelecting = false;
        _rightClickStartLatLng = null;
        _rightClickCurrentLatLng = null;
        _hoveredPoint = null;
        _hoveredLatLng = null;
      });
      return;
    }

    if (_isDraggingHoverDot) {
      final appState = context.read<AppStateProvider>();
      final dateInfo = _currentDateInfo(appState);

      if (_draggedHoverDotInsertIndex != null &&
          _draggedHoverDotCurrentLatLng != null &&
          _draggedHoverDotTime != null) {
        final newPoint = LocationPoint(
          latitude: _draggedHoverDotCurrentLatLng!.latitude,
          longitude: _draggedHoverDotCurrentLatLng!.longitude,
          timestamp: _draggedHoverDotTime!,
        );

        if (appState.isEditing) {
          appState.insertPoint(_draggedHoverDotInsertIndex!,
              _draggedHoverDotCurrentLatLng!, 0.0);
        } else {
          final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
          final updated = List<LocationPoint>.from(dayPoints);

          // Save backup for session Undo before manual edit
          if (_draggedHoverDotSegment != null) {
            final key = _getSegmentKey(_draggedHoverDotSegment!.startTime,
                _draggedHoverDotSegment!.endTime);
            _unsnappedSegmentBackups[key] =
                List<LocationPoint>.from(_draggedHoverDotSegment!.points);
          }

          // Move existing point if dragging a vertex, or insert if dragging line segment
          final existingIdx = updated.indexWhere((p) =>
              p.timestamp.millisecondsSinceEpoch ==
              _draggedHoverDotTime!.millisecondsSinceEpoch);

          if (existingIdx != -1) {
            updated[existingIdx] = newPoint;
          } else {
            updated.insert(_draggedHoverDotInsertIndex!, newPoint);
          }

          // Repaint immediately with 0ms latency, then save to disk async
          appState.updateActivePathInMemory(dateInfo, updated);

          if (_autoSnapOnDrag && _draggedHoverDotSegment != null && mounted) {
            _snapSegmentToRoads(
                context, appState, dateInfo, updated, _draggedHoverDotSegment!);
          }

          // Persist to disk asynchronously (does NOT block UI)
          _saveWithIndicator(appState, dateInfo, updated);
        }
      }

      setState(() {
        _isDraggingHoverDot = false;
        _draggedHoverDotTime = null;
        _draggedHoverDotInsertIndex = null;
        _draggedHoverDotCurrentLatLng = null;
        _draggedHoverDotSegment = null;
        _hoveredPoint = null;
        _hoveredColor = null;
        _hoveredLatLng = null;
      });
      return;
    }

    if (_isDraggingPhoto) {
      setState(() {
        _isDraggingPhoto = false;
        _draggingPhoto = null;
      });
      // Re-assign photos to timeline items after drag completes
      final appState = context.read<AppStateProvider>();
      final settings = context.read<SettingsProvider>();
      final dateInfo = _currentDateInfo(appState);
      final points = appState.activePaths[dateInfo.filePath] ?? [];
      _assignPhotosToTimelineItems(points, settings.geotagTimezone.toDouble());
      return;
    }

    if (_isDraggingPoint) {
      setState(() {
        _isDraggingPoint = false;
      });
      _snapAfterDragRelease();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Road snapping — _fetchRouteCoordinates, _snapAfterDragRelease
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<LatLng>> _fetchRouteCoordinates(
      LatLng start, LatLng end, bool useGoogle, String googleApiKey) async {
    if (useGoogle) {
      final url =
          'https://roads.googleapis.com/v1/snapToRoads?path=${start.latitude},${start.longitude}|${end.latitude},${end.longitude}&interpolate=true&key=$googleApiKey';
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final data = jsonDecode(responseBody);
          if (data['snappedPoints'] != null) {
            final List snapped = data['snappedPoints'];
            return snapped.map((s) {
              final lat = s['location']['latitude'] as double;
              final lng = s['location']['longitude'] as double;
              return LatLng(lat, lng);
            }).toList();
          }
        }
      } catch (e) {
        debugPrint('Google Roads API failed: $e');
      } finally {
        client.close();
      }
    } else {
      final url = 'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
          '?overview=full&geometries=geojson';
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final data = jsonDecode(responseBody);
          if (data['routes'] != null && data['routes'].isNotEmpty) {
            final geometry = data['routes'][0]['geometry'];
            final coordinates = geometry['coordinates'] as List;
            return coordinates.map((coord) {
              final lng = coord[0] as double;
              final lat = coord[1] as double;
              return LatLng(lat, lng);
            }).toList();
          }
        }
      } catch (e) {
        debugPrint('OSRM routing failed: $e');
      } finally {
        client.close();
      }
    }
    return [];
  }

  Future<void> _snapAfterDragRelease() async {
    final draggedIdx = _selectedPointIndex;
    if (draggedIdx == null) return;

    final appState = context.read<AppStateProvider>();
    appState.pinnedPointIndices.add(draggedIdx);

    final settings = context.read<SettingsProvider>();
    final useGoogle = settings.routingProvider == 'google';
    final googleApiKey = settings.googleMapsApiKey;

    if (useGoogle && googleApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Please configure your Google Maps API Key in Settings to snap roads.')),
      );
      return;
    }

    final editingPoints = List<LocationPoint>.from(appState.editingPoints);
    final pinnedIndices = Set<int>.from(appState.pinnedPointIndices);

    int a = 0;
    for (int i = draggedIdx - 1; i >= 0; i--) {
      if (pinnedIndices.contains(i)) {
        a = i;
        break;
      }
    }

    int b = editingPoints.length - 1;
    for (int i = draggedIdx + 1; i < editingPoints.length; i++) {
      if (pinnedIndices.contains(i)) {
        b = i;
        break;
      }
    }

    // Parallel fetch routes
    final futures = await Future.wait([
      _fetchRouteCoordinates(editingPoints[a].latLng,
          editingPoints[draggedIdx].latLng, useGoogle, googleApiKey),
      _fetchRouteCoordinates(editingPoints[draggedIdx].latLng,
          editingPoints[b].latLng, useGoogle, googleApiKey),
    ]);

    final List<LatLng> route1 = futures[0];
    final List<LatLng> route2 = futures[1];

    if (route1.isEmpty && route2.isEmpty) {
      return;
    }

    final List<LocationPoint> finalPoints = [];

    // 1. Copy points before 'a'
    for (int i = 0; i < a; i++) {
      finalPoints.add(editingPoints[i]);
    }

    // 2. Add snapped points from 'a' to 'draggedIdx'
    final tA = editingPoints[a].timestamp;
    final tDragged = editingPoints[draggedIdx].timestamp;
    final duration1 = tDragged.difference(tA);

    final List<LocationPoint> segment1 = [];
    if (route1.isNotEmpty) {
      final List<double> dists = [0.0];
      double totalD = 0.0;
      for (int k = 0; k < route1.length - 1; k++) {
        final d = GeoUtils.distanceBetween(route1[k], route1[k + 1]);
        totalD += d;
        dists.add(totalD);
      }
      for (int k = 0; k < route1.length; k++) {
        final ratio =
            totalD > 0 ? (dists[k] / totalD) : (k / (route1.length - 1));
        segment1.add(LocationPoint(
          latitude: route1[k].latitude,
          longitude: route1[k].longitude,
          timestamp: tA.add(duration1 * ratio),
          elevation: editingPoints[a].elevation,
          activityType: editingPoints[a].activityType,
        ));
      }
    } else {
      for (int i = a; i <= draggedIdx; i++) {
        segment1.add(editingPoints[i]);
      }
    }
    finalPoints.addAll(segment1);

    // 3. Add snapped points from 'draggedIdx' to 'b'
    final tB = editingPoints[b].timestamp;
    final duration2 = tB.difference(tDragged);

    final List<LocationPoint> segment2 = [];
    if (route2.isNotEmpty) {
      final List<double> dists = [0.0];
      double totalD = 0.0;
      for (int k = 0; k < route2.length - 1; k++) {
        final d = GeoUtils.distanceBetween(route2[k], route2[k + 1]);
        totalD += d;
        dists.add(totalD);
      }
      for (int k = 1; k < route2.length; k++) {
        final ratio =
            totalD > 0 ? (dists[k] / totalD) : (k / (route2.length - 1));
        segment2.add(LocationPoint(
          latitude: route2[k].latitude,
          longitude: route2[k].longitude,
          timestamp: tDragged.add(duration2 * ratio),
          elevation: editingPoints[draggedIdx].elevation,
          activityType: editingPoints[draggedIdx].activityType,
        ));
      }
    } else {
      for (int i = draggedIdx + 1; i <= b; i++) {
        segment2.add(editingPoints[i]);
      }
    }
    finalPoints.addAll(segment2);

    // 4. Copy points after 'b'
    for (int i = b + 1; i < editingPoints.length; i++) {
      finalPoints.add(editingPoints[i]);
    }

    final Set<int> newPinnedIndices = {0, finalPoints.length - 1};

    for (final oldIdx in pinnedIndices) {
      if (oldIdx == 0 || oldIdx == editingPoints.length - 1) continue;
      final oldTime = editingPoints[oldIdx].timestamp;

      int nearestIdx = 0;
      int minDiffMs = double.maxFinite.toInt();
      for (int i = 0; i < finalPoints.length; i++) {
        final diff =
            finalPoints[i].timestamp.difference(oldTime).inMilliseconds.abs();
        if (diff < minDiffMs) {
          minDiffMs = diff;
          nearestIdx = i;
        }
      }
      newPinnedIndices.add(nearestIdx);
    }

    appState.setEditingPoints(finalPoints);
    appState.setPinnedPointIndices(newPinnedIndices);

    final oldTime = editingPoints[draggedIdx].timestamp;
    int nearestIdx = 0;
    int minDiffMs = double.maxFinite.toInt();
    for (int i = 0; i < finalPoints.length; i++) {
      final diff =
          finalPoints[i].timestamp.difference(oldTime).inMilliseconds.abs();
      if (diff < minDiffMs) {
        minDiffMs = diff;
        nearestIdx = i;
      }
    }
    setState(() {
      _selectedPointIndex = nearestIdx;
    });
  }

  String _formatPointTime(DateTime utcTime, double timezoneOffset) {
    final localTime =
        utcTime.add(Duration(minutes: (timezoneOffset * 60).toInt()));
    return DateFormat('HH:mm:ss').format(localTime);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Point dialogs — add point, edit point
  // ─────────────────────────────────────────────────────────────────────────

  void _openAddPointDialog(BuildContext context, AppStateProvider appState,
      DateInfo dateInfo, List<LocationPoint> currentPoints) {
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();
    final timeCtrl = TextEditingController(
        text: DateFormat('HH:mm:ss').format(DateTime.now()));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Timeline Point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latCtrl,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextField(
              controller: lngCtrl,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextField(
              controller: timeCtrl,
              decoration: const InputDecoration(labelText: 'Time (HH:mm:ss)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final lat = double.tryParse(latCtrl.text);
              final lng = double.tryParse(lngCtrl.text);
              if (lat == null || lng == null) return;

              try {
                final timeParts = timeCtrl.text.split(':');
                if (timeParts.length != 3) throw Exception('Format error');
                final hr = int.parse(timeParts[0]);
                final min = int.parse(timeParts[1]);
                final sec = int.parse(timeParts[2]);

                final utcDate = DateTime.utc(
                  dateInfo.date.year,
                  dateInfo.date.month,
                  dateInfo.date.day,
                  hr,
                  min,
                  sec,
                );

                final newPoint = LocationPoint(
                  latitude: lat,
                  longitude: lng,
                  timestamp: utcDate,
                );

                final newPoints = List<LocationPoint>.from(currentPoints)
                  ..add(newPoint);
                await appState.saveListPoints(dateInfo, newPoints);
                _loadPointsForSelectedDate();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Invalid time format. Use HH:mm:ss.')),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _openEditPointDialog(BuildContext context, AppStateProvider appState,
      DateInfo dateInfo, List<LocationPoint> currentPoints, int index) {
    final pt = currentPoints[index];
    final settings = context.read<SettingsProvider>();
    final offset = settings.geotagTimezone.toDouble();

    final latCtrl = TextEditingController(text: pt.latitude.toString());
    final lngCtrl = TextEditingController(text: pt.longitude.toString());

    final localTime =
        pt.timestamp.add(Duration(minutes: (offset * 60).toInt()));
    final timeCtrl =
        TextEditingController(text: DateFormat('HH:mm:ss').format(localTime));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Timeline Point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latCtrl,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextField(
              controller: lngCtrl,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextField(
              controller: timeCtrl,
              decoration: const InputDecoration(labelText: 'Time (HH:mm:ss)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final lat = double.tryParse(latCtrl.text);
              final lng = double.tryParse(lngCtrl.text);
              if (lat == null || lng == null) return;

              try {
                final timeParts = timeCtrl.text.split(':');
                if (timeParts.length != 3) throw Exception('Format error');
                final hr = int.parse(timeParts[0]);
                final min = int.parse(timeParts[1]);
                final sec = int.parse(timeParts[2]);

                final localDate = DateTime(
                  dateInfo.date.year,
                  dateInfo.date.month,
                  dateInfo.date.day,
                  hr,
                  min,
                  sec,
                );
                final utcDate = localDate
                    .subtract(Duration(minutes: (offset * 60).toInt()));

                final updatedPoint = LocationPoint(
                  latitude: lat,
                  longitude: lng,
                  timestamp: utcDate,
                  elevation: pt.elevation,
                  activityType: pt.activityType,
                );

                final newPoints = List<LocationPoint>.from(currentPoints);
                newPoints[index] = updatedPoint;

                await appState.saveListPoints(dateInfo, newPoints);
                _loadPointsForSelectedDate();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Invalid time format. Use HH:mm:ss.')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Sidebar — date list, day stats, source controls, action buttons
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSidebar(BuildContext context, AppStateProvider appState,
      DateInfo dateInfo, List<LocationPoint> points) {
    final settings = context.read<SettingsProvider>();
    final double offset = settings.geotagTimezone.toDouble();
    final isEditing = appState.isEditing;

    final dateStr = _selectedDate == null
        ? 'Select Date'
        : DateFormat('MMMM dd, yyyy').format(_selectedDate!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.map_outlined,
                      color: Theme.of(context).colorScheme.primary, size: 28),
                  const SizedBox(width: 8),
                  Text(
                    'Timeline Map',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Day Dropdown
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedDate?.day,
                                items: List.generate(
                                  DateTime(
                                          _selectedDate?.year ??
                                              DateTime.now().year,
                                          (_selectedDate?.month ??
                                                  DateTime.now().month) +
                                              1,
                                          0)
                                      .day,
                                  (i) => i + 1,
                                )
                                    .map((d) => DropdownMenuItem(
                                          value: d,
                                          child: Center(
                                            child: Text(
                                              d.toString().padLeft(2, '0'),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14),
                                            ),
                                          ),
                                        ))
                                    .toList(),
                                onChanged: (day) {
                                  if (day != null) {
                                    setState(() {
                                      _selectedDate = DateTime(
                                          _selectedDate!.year,
                                          _selectedDate!.month,
                                          day);
                                    });
                                    _loadPointsForSelectedDate();
                                  }
                                },
                              ),
                            ),
                          ),
                          const Text('/',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 14)),
                          // Month Dropdown
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedDate?.month,
                                items: List.generate(12, (i) => i + 1)
                                    .map((m) => DropdownMenuItem(
                                          value: m,
                                          child: Center(
                                            child: Text(
                                              m.toString().padLeft(2, '0'),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14),
                                            ),
                                          ),
                                        ))
                                    .toList(),
                                onChanged: (month) {
                                  if (month != null) {
                                    final daysInMonth = DateTime(
                                            _selectedDate!.year, month + 1, 0)
                                        .day;
                                    final targetDay = _selectedDate!.day
                                        .clamp(1, daysInMonth);
                                    setState(() {
                                      _selectedDate = DateTime(
                                          _selectedDate!.year,
                                          month,
                                          targetDay);
                                    });
                                    _loadPointsForSelectedDate();
                                  }
                                },
                              ),
                            ),
                          ),
                          const Text('/',
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 14)),
                          // Year Dropdown
                          Expanded(
                            flex: 2,
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedDate?.year,
                                items: List.generate(
                                        DateTime.now().year - 2000 + 1,
                                        (i) => 2000 + i)
                                    .map((y) => DropdownMenuItem(
                                          value: y,
                                          child: Center(
                                            child: Text(
                                              y.toString(),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14),
                                            ),
                                          ),
                                        ))
                                    .toList(),
                                onChanged: (year) {
                                  if (year != null) {
                                    final daysInMonth = DateTime(
                                            year, _selectedDate!.month + 1, 0)
                                        .day;
                                    final targetDay = _selectedDate!.day
                                        .clamp(1, daysInMonth);
                                    setState(() {
                                      _selectedDate = DateTime(year,
                                          _selectedDate!.month, targetDay);
                                    });
                                    _loadPointsForSelectedDate();
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    icon: Icon(_showCalendar
                        ? Icons.calendar_today
                        : Icons.calendar_month),
                    onPressed: () {
                      setState(() {
                        _showCalendar = !_showCalendar;
                      });
                    },
                    tooltip: _showCalendar ? 'Hide Calendar' : 'Show Calendar',
                  ),
                ],
              ),
            ],
          ),
        ),

        // Controls action row
        if (dateInfo.filePath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                // Snap to Roads
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isEditing
                        ? null
                        : () async {
                            await appState.snapToRoads(dateInfo);
                            _loadPointsForSelectedDate();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Snapped timeline to roads! (Simulated)')),
                              );
                            }
                          },
                    icon: const Icon(Icons.alt_route),
                    label: const Text('Snap Roads'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: dateInfo.state == 'snapped'
                          ? Colors.green.shade50
                          : null,
                      foregroundColor: dateInfo.state == 'snapped'
                          ? Colors.green.shade800
                          : null,
                      side: dateInfo.state == 'snapped'
                          ? BorderSide(color: Colors.green.shade200)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Restore Original
                IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: 'Restore Original Backup',
                  onPressed: isEditing
                      ? null
                      : () async {
                          await appState.restoreDateToOriginal(dateInfo);
                          _loadPointsForSelectedDate();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Restored timeline to original backup.')),
                            );
                          }
                        },
                ),
                // Delete Day
                IconButton(
                  icon: const Icon(Icons.delete_forever, color: Colors.red),
                  tooltip: 'Delete Timeline',
                  onPressed: isEditing
                      ? null
                      : () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete Timeline'),
                              content: Text(
                                  'Are you sure you want to delete all timeline records for $dateStr?'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await appState.deleteDate(dateInfo);
                            setState(() {
                              _selectedDate = null;
                            });
                          }
                        },
                ),
              ],
            ),
          ),

        // Source dropdown
        if (dateInfo.hasTimelineBackup && dateInfo.hasGpxBackup)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                const Text('Data Source: ',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: dateInfo.source,
                    decoration: const InputDecoration(
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: 'merge', child: Text('Merge (Auto)')),
                      DropdownMenuItem(
                          value: 'timeline', child: Text('Google Timeline')),
                      DropdownMenuItem(value: 'gpx', child: Text('GPX Only')),
                    ],
                    onChanged: isEditing
                        ? null
                        : (val) async {
                            if (val != null) {
                              await appState.updateDaySource(dateInfo, val);
                              _loadPointsForSelectedDate();
                            }
                          },
                  ),
                ),
              ],
            ),
          ),

        // Monthly Distance chart
        if (_selectedDate != null)
          MonthlyDistanceChart(
            selectedDate: _selectedDate!,
            allDates: appState.allDates,
            points: points,
            timezoneOffset: offset,
            onDateSelected: (date) {
              setState(() {
                _selectedDate = date;
              });
              _loadPointsForSelectedDate();
            },
          ),

        // Points Details List
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: dateInfo.filePath.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'No location data for this day.\nImport GPX or Timeline JSON first.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                        child: Row(
                          children: [
                            Text(
                              _viewAsPath
                                  ? 'Timeline'
                                  : 'Track Details (${points.length} pts)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            Tooltip(
                              message: _autoSnapOnDrag
                                  ? 'Auto Snap on Drag: ON'
                                  : 'Auto Snap on Drag: OFF',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.alt_route,
                                    size: 18,
                                    color: _autoSnapOnDrag
                                        ? Colors.green
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Auto Snap',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Transform.scale(
                                    scale: 0.75,
                                    child: Switch(
                                      value: _autoSnapOnDrag,
                                      activeThumbColor: Colors.green,
                                      onChanged: (val) {
                                        setState(() {
                                          _autoSnapOnDrag = val;
                                        });
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              _autoSnapOnDrag
                                                  ? 'Auto-snap on drag enabled!'
                                                  : 'Auto-snap on drag disabled.',
                                            ),
                                            duration:
                                                const Duration(seconds: 1),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                  _viewAsPath ? Icons.list : Icons.timeline),
                              onPressed: () {
                                setState(() {
                                  _viewAsPath = !_viewAsPath;
                                });
                              },
                              tooltip: _viewAsPath
                                  ? 'Show Raw List'
                                  : 'Show Timeline',
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline,
                                  color: Colors.blue),
                              onPressed: isEditing || _viewAsPath
                                  ? null
                                  : () => _openAddPointDialog(
                                      context, appState, dateInfo, points),
                              tooltip: 'Add Coordinate',
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _viewAsPath
                            ? () {
                                final timelineItems =
                                    _timelineItemsWithPhotos ??
                                        _clusterTimeline(points, offset);
                                if (timelineItems.isEmpty) {
                                  return const Center(
                                    child: Text('No timeline points.'),
                                  );
                                }
                                return ListView.builder(
                                  itemCount: timelineItems.length,
                                  itemBuilder: (context, idx) {
                                    final isSelected =
                                        _selectedTimelineItemIndex == idx;
                                    final isFirst = idx == 0;
                                    final isLast =
                                        idx == timelineItems.length - 1;
                                    return _buildTimelineItem(
                                        context,
                                        timelineItems,
                                        idx,
                                        offset,
                                        isSelected,
                                        isFirst,
                                        isLast);
                                  },
                                );
                              }()
                            : ListView.builder(
                                itemCount: points.length,
                                itemBuilder: (context, idx) {
                                  final p = points[idx];
                                  return ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 0),
                                    leading: CircleAvatar(
                                      radius: 10,
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      child: Text(
                                        (idx + 1).toString(),
                                        style: TextStyle(
                                            fontSize: 8,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onPrimaryContainer),
                                      ),
                                    ),
                                    title: Text(
                                      _formatPointTime(p.timestamp, offset),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                    subtitle: Text(
                                      '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}',
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon:
                                              const Icon(Icons.edit, size: 16),
                                          onPressed: isEditing
                                              ? null
                                              : () => _openEditPointDialog(
                                                  context,
                                                  appState,
                                                  dateInfo,
                                                  points,
                                                  idx),
                                          tooltip: 'Edit Point',
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline,
                                              size: 16, color: Colors.red),
                                          onPressed: isEditing
                                              ? null
                                              : () async {
                                                  final confirm =
                                                      await showDialog<bool>(
                                                    context: context,
                                                    builder: (ctx) =>
                                                        AlertDialog(
                                                      title: const Text(
                                                          'Delete Point'),
                                                      content: const Text(
                                                          'Delete this coordinate point from the timeline?'),
                                                      actions: [
                                                        TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                    ctx, false),
                                                            child: const Text(
                                                                'Cancel')),
                                                        ElevatedButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                  ctx, true),
                                                          style: ElevatedButton
                                                              .styleFrom(
                                                                  backgroundColor:
                                                                      Colors
                                                                          .red,
                                                                  foregroundColor:
                                                                      Colors
                                                                          .white),
                                                          child: const Text(
                                                              'Delete'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (confirm == true) {
                                                    final newPts = List<
                                                            LocationPoint>.from(
                                                        points)
                                                      ..removeAt(idx);
                                                    await appState
                                                        .saveListPoints(
                                                            dateInfo, newPts);
                                                    _loadPointsForSelectedDate();
                                                  }
                                                },
                                          tooltip: 'Delete Point',
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      _animatedMapMove(
                                          p.latLng, _mapController.camera.zoom);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Map layer builders — tile layer, map build, markers, polylines
  // ─────────────────────────────────────────────────────────────────────────

  TileLayer _buildTileLayer(String mapProvider) {
    String urlTemplate;
    TileProvider tileProvider = CachedTileProvider();

    switch (mapProvider) {
      case 'google_roadmap':
        urlTemplate = 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
        break;
      case 'google_satellite':
        urlTemplate = 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}';
        break;
      case 'bing_roadmap':
        urlTemplate =
            'http://ecn.t3.tiles.virtualearth.net/tiles/r{quadkey}.jpeg?g=1';
        tileProvider = BingTileProvider();
        break;
      case 'bing_satellite':
        urlTemplate =
            'http://ecn.t3.tiles.virtualearth.net/tiles/a{quadkey}.jpeg?g=1';
        tileProvider = BingTileProvider();
        break;
      case 'osm':
      default:
        urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
        break;
    }

    return TileLayer(
      urlTemplate: urlTemplate,
      tileProvider: tileProvider,
      userAgentPackageName: 'com.dangphuc.creation_date_changer',
    );
  }

  Widget _buildMap(BuildContext context, AppStateProvider appState,
      SettingsProvider settings, List<LocationPoint> pointsToShow) {
    final isEditing = appState.isEditing;
    final mapProvider = settings.mapProvider;
    final double timeOffset = settings.geotagTimezone.toDouble();

    // Resolve Map Tiles
    final tileLayer = _buildTileLayer(mapProvider);

    // Build Polylines
    final List<Polyline> polylines = [];

    // Find the currently selected date info to identify its file path
    final currentDayInfo = appState.allDates.firstWhere(
      (d) =>
          _selectedDate != null &&
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.date.day == _selectedDate!.day,
      orElse: () => DateInfo(
        date: _selectedDate ?? DateTime.now(),
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    // Draw all other active paths in grey first
    for (final entry in appState.activePaths.entries) {
      final filePath = entry.key;
      if (filePath == currentDayInfo.filePath) continue;

      final pts = entry.value;
      if (pts.isNotEmpty) {
        polylines.add(
          Polyline(
            points: pts.map((p) => p.latLng).toList(),
            strokeWidth: TimelineConstants.polylineStrokeWidthInactive,
            color: Colors.grey.withValues(alpha: 0.4),
          ),
        );
      }
    }

    // Determine selection item details if viewAsPath is true
    final timelineItems = _clusterTimeline(pointsToShow, timeOffset);
    LatLng? selectedStayPointIncomingStart;
    LatLng? selectedStayPointOutgoingEnd;
    TimelinePath? selectedMoveSegment;

    if (_viewAsPath &&
        _selectedTimelineItemIndex != null &&
        _selectedTimelineItemIndex! < timelineItems.length) {
      final selectedItem = timelineItems[_selectedTimelineItemIndex!];
      if (selectedItem is TimelinePlace) {
        // Incoming segment start point
        if (_selectedTimelineItemIndex! - 1 >= 0) {
          final incoming = timelineItems[_selectedTimelineItemIndex! - 1];
          if (incoming is TimelinePath && incoming.points.isNotEmpty) {
            selectedStayPointIncomingStart = incoming.points.first.latLng;
          }
        }

        // Outgoing segment end point
        if (_selectedTimelineItemIndex! + 1 < timelineItems.length) {
          final outgoing = timelineItems[_selectedTimelineItemIndex! + 1];
          if (outgoing is TimelinePath && outgoing.points.isNotEmpty) {
            selectedStayPointOutgoingEnd = outgoing.points.last.latLng;
          }
        }
      } else if (selectedItem is TimelinePath) {
        selectedMoveSegment = selectedItem;
      }
    }

    // Draw the currently selected active path on top
    if (pointsToShow.isNotEmpty) {
      if (isEditing) {
        polylines.add(
          Polyline(
            points: pointsToShow.map((p) => p.latLng).toList(),
            strokeWidth: TimelineConstants.polylineStrokeWidthEditing,
            color: TimelineConstants.editRouteColor,
          ),
        );
      } else if (_viewAsPath && timelineItems.isNotEmpty) {
        // Render each TimelinePath as a separate polyline with conditional colors/thickness
        for (int idx = 0; idx < timelineItems.length; idx++) {
          final item = timelineItems[idx];
          if (item is TimelinePath && item.points.isNotEmpty) {
            Color lineColor;
            double width;

            final hasTimelineSelection = (_selectedTimelineItemIndex != null);

            if (hasTimelineSelection) {
              final selectedItem = timelineItems[_selectedTimelineItemIndex!];

              final isHovered = (_hoveredTimelineItemIndex == idx);
              if (selectedItem is TimelinePath) {
                // If a move segment is selected, only highlight that exact segment
                if (_selectedTimelineItemIndex == idx) {
                  lineColor = TimelineConstants.activeRouteColor;
                  width = TimelineConstants.polylineStrokeWidthSelected;
                } else if (isHovered) {
                  lineColor = TimelineConstants.activeRouteColor
                      .withValues(alpha: 0.65);
                  width = 4.5;
                } else {
                  lineColor = TimelineConstants.activeRouteColor
                      .withValues(alpha: 0.15);
                  width = TimelineConstants.polylineStrokeWidthUnselected;
                }
              } else if (selectedItem is TimelinePlace) {
                // If a stay point is selected, highlight only the 2 adjacent roads
                final isAdjacent = (idx == _selectedTimelineItemIndex! - 1) ||
                    (idx == _selectedTimelineItemIndex! + 1);
                if (isAdjacent) {
                  lineColor = TimelineConstants.activeRouteColor;
                  width = TimelineConstants.polylineStrokeWidthSelected;
                } else if (isHovered) {
                  lineColor = TimelineConstants.activeRouteColor
                      .withValues(alpha: 0.65);
                  width = 4.5;
                } else {
                  lineColor = TimelineConstants.activeRouteColor
                      .withValues(alpha: 0.15);
                  width = TimelineConstants.polylineStrokeWidthUnselected;
                }
              } else {
                lineColor = TimelineConstants.activeRouteColor;
                width = TimelineConstants.polylineStrokeWidthDefault;
              }
            } else {
              final isHovered = (_hoveredTimelineItemIndex == idx);
              lineColor = TimelineConstants.activeRouteColor;
              width = isHovered
                  ? 5.5
                  : TimelineConstants.polylineStrokeWidthDefault;
            }

            final List<LatLng> pathLatLngs =
                item.points.map((p) => p.latLng).toList();

            // Dynamically connect adjacent incoming/outgoing path endpoints to live dragged Place
            if (_isDraggingPlace &&
                _draggingPlaceIndex != null &&
                _draggedPlaceCurrentLatLng != null) {
              if (idx == _draggingPlaceIndex! - 1 && pathLatLngs.isNotEmpty) {
                pathLatLngs[pathLatLngs.length - 1] =
                    _draggedPlaceCurrentLatLng!;
              } else if (idx == _draggingPlaceIndex! + 1 &&
                  pathLatLngs.isNotEmpty) {
                pathLatLngs[0] = _draggedPlaceCurrentLatLng!;
              }
            }

            polylines.add(
              Polyline(
                points: pathLatLngs,
                strokeWidth: width,
                color: lineColor,
              ),
            );
          }
        }
      } else {
        // Standard path view
        polylines.add(
          Polyline(
            points: pointsToShow.map((p) => p.latLng).toList(),
            strokeWidth: 4.0,
            color: Colors.purple,
          ),
        );
      }
    }

    // Build Markers
    final List<Marker> markers = [];
    if (isEditing) {
      final pinnedIndices = appState.pinnedPointIndices;
      for (int i = 0; i < pointsToShow.length; i++) {
        final pt = pointsToShow[i];
        final isPinned = pinnedIndices.contains(i);
        final isSelected = _selectedPointIndex == i;

        markers.add(
          Marker(
            point: pt.latLng,
            width: isSelected ? 24 : 16,
            height: isSelected ? 24 : 16,
            child: GestureDetector(
              onLongPress: () {
                appState.togglePin(i);
              },
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.yellow
                      : (isPinned ? Colors.red : Colors.orange),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2)),
                  ],
                ),
                child: Center(
                  child: Text(
                    (i + 1).toString(),
                    style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.black : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    // Hover projection marker
    if (isEditing && _hoveredLatLng != null) {
      markers.add(
        Marker(
          point: _hoveredLatLng!,
          width: 14,
          height: 14,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      );
    }

    // Render Place markers for all TimelinePlace items on the map
    if (!isEditing && _viewAsPath && timelineItems.isNotEmpty) {
      final hasTimelineSelection = (_selectedTimelineItemIndex != null);

      for (int idx = 0; idx < timelineItems.length; idx++) {
        final item = timelineItems[idx];
        if (item is TimelinePlace) {
          final isSelected = (_selectedTimelineItemIndex == idx);
          final isHovered = (_hoveredTimelineItemIndex == idx);
          double opacity = 1.0;
          double size = 32.0;

          if (hasTimelineSelection) {
            if (isSelected) {
              opacity = 1.0;
              size = 38.0;
            } else if (isHovered) {
              opacity = 0.65;
              size = 34.0;
            } else {
              opacity = 0.25;
              size = 28.0;
            }
          } else {
            if (isHovered) {
              opacity = 1.0;
              size = 36.0;
            }
          }

          LatLng placePoint = item.center;
          if (_isDraggingPlace &&
              _draggingPlaceIndex == idx &&
              _draggedPlaceCurrentLatLng != null) {
            placePoint = _draggedPlaceCurrentLatLng!;
          }

          markers.add(
            Marker(
              point: placePoint,
              width: size,
              height: size,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedTimelineItemIndex = idx;
                  });
                },
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    decoration: BoxDecoration(
                      color: TimelineConstants.stayPointIconColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: isSelected ? 3 : 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black38,
                          blurRadius: isSelected ? 6 : 3,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.place,
                      color: Colors.white,
                      size: isSelected ? 22 : 16,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    // Selected Stay Point incoming and outgoing endpoint markers
    if (!isEditing && selectedStayPointIncomingStart != null) {
      markers.add(
        Marker(
          point: selectedStayPointIncomingStart,
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: TimelineConstants.activeRouteColor.withValues(alpha: 0.5),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      );
    }

    if (!isEditing && selectedStayPointOutgoingEnd != null) {
      markers.add(
        Marker(
          point: selectedStayPointOutgoingEnd,
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: TimelineConstants.activeRouteColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      );
    }

    // Selected Move Segment start and end point markers
    if (!isEditing &&
        selectedMoveSegment != null &&
        selectedMoveSegment.points.isNotEmpty) {
      final startPt = selectedMoveSegment.points.first;
      final endPt = selectedMoveSegment.points.last;

      markers.add(
        Marker(
          point: startPt.latLng,
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: TimelineConstants.activeRouteColor.withValues(alpha: 0.5),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      );

      markers.add(
        Marker(
          point: endPt.latLng,
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: TimelineConstants.activeRouteColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      );
    }

    // Translucent white dots for all active points on the path when hovering
    if (!isEditing && _hoveredLatLng != null) {
      final activeHoverPts = _getActiveHoverPoints(pointsToShow, timeOffset);
      for (final p in activeHoverPts) {
        markers.add(
          Marker(
            point: p.latLng,
            width: 10,
            height: 10,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.75),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.purple.withValues(alpha: 0.8), width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 2),
                ],
              ),
            ),
          ),
        );
      }
    }

    // Hover point in non-edit mode
    if (!isEditing && _hoveredPoint != null && _hoveredLatLng != null) {
      final localHoverTime = _hoveredPoint!.timestamp
          .add(Duration(minutes: (timeOffset * 60).toInt()));
      markers.add(
        Marker(
          point: _hoveredLatLng!,
          width: 200,
          height: 120,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _hoveredColor == Colors.white
                      ? Colors.white
                      : (_hoveredColor ?? const Color(0xFF7F92FF)),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _hoveredColor == Colors.white
                        ? Colors.purple
                        : Colors.white,
                    width: 2.5,
                  ),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 6),
                  ],
                ),
              ),
              Positioned(
                bottom: 24,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black45,
                          blurRadius: 4,
                          offset: Offset(0, 2)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat('HH:mm:ss').format(localHoverTime),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ── Photo markers ────────────────────────────────────────────────────
    // Two visual marker types:
    //   • Geotagged (has EXIF GPS): white border
    //   • Ungeotagged (interpolated location): light-blue border
    for (final photo in _currentDatePhotos) {
      final loc = photo.assignedLatLng;
      if (loc == null) continue;

      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isSelected =
          _selectedPhoto == photo || _selectedPhotoSet.contains(photo);
      final isDragging = _draggingPhoto == photo;
      final isGeotagged = photo.hasExifGps;

      final Color borderColor = isDragging || isSelected
          ? Colors.amber
          : (isGeotagged ? Colors.white70 : Colors.lightBlue.shade200);

      final double size = isDragging ? 64 : (isSelected ? 58 : 48);

      markers.add(Marker(
        point: loc,
        width: size,
        height: size,
        child: GestureDetector(
          onTap: () => setState(() {
            if (isCtrl) {
              if (_selectedPhotoSet.contains(photo)) {
                _selectedPhotoSet.remove(photo);
              } else {
                _selectedPhotoSet.add(photo);
              }
            } else {
              _selectedPhotoSet.clear();
              _selectedPhoto = (_selectedPhoto == photo) ? null : photo;
              _showPhotoGrid = false;
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border:
                  Border.all(color: borderColor, width: isSelected ? 2.5 : 1.5),
            ),
            child: ClipOval(
              child: Image.file(
                photo.file,
                fit: BoxFit.cover,
                cacheWidth: 120,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image, size: 20),
                ),
              ),
            ),
          ),
        ),
      ));
    }

    final List<Polygon> polygons = [];
    if (_isRightClickSelecting &&
        _rightClickStartLatLng != null &&
        _rightClickCurrentLatLng != null) {
      final start = _rightClickStartLatLng!;
      final end = _rightClickCurrentLatLng!;
      final minLat = min(start.latitude, end.latitude);
      final maxLat = max(start.latitude, end.latitude);
      final minLng = min(start.longitude, end.longitude);
      final maxLng = max(start.longitude, end.longitude);

      polygons.add(
        Polygon(
          points: [
            LatLng(minLat, minLng),
            LatLng(minLat, maxLng),
            LatLng(maxLat, maxLng),
            LatLng(maxLat, minLng),
          ],
          color: Colors.red.withValues(alpha: 0.2),
          borderColor: Colors.red,
          borderStrokeWidth: 2,
        ),
      );

      final activeHoverPts = _getActiveHoverPoints(pointsToShow, timeOffset);
      for (final p in activeHoverPts) {
        if (p.latitude >= minLat &&
            p.latitude <= maxLat &&
            p.longitude >= minLng &&
            p.longitude <= maxLng) {
          markers.add(
            Marker(
              point: p.latLng,
              width: 14,
              height: 14,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 4),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }

    return MapWidget(
      mapController: _mapController,
      tileLayer: tileLayer,
      polylines: polylines,
      polygons: polygons,
      markers: markers,
      isEditing: isEditing,
      isRightClickSelecting: _isRightClickSelecting,
      isDraggingHoverDot: _isDraggingHoverDot,
      isDraggingPlace: _isDraggingPlace,
      onHover: _handleHover,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      hoveredProjection: _hoveredProjection,
      pointsToShow: pointsToShow,
      timezoneOffset: timeOffset,
      formatPointTime: _formatPointTime,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final settings = context.watch<SettingsProvider>();
    final isEditing = appState.isEditing;
    final timeOffset = settings.geotagTimezone.toDouble();

    // Make sure we have selectedDate initialized
    if (_selectedDate == null) {
      if (appState.allDates.isNotEmpty) {
        _selectedDate = appState.allDates.first.date;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadPointsForSelectedDate();
        });
      } else {
        _selectedDate = DateTime.now();
      }
    }

    final currentDateInfo = appState.allDates.firstWhere(
      (d) =>
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.date.day == _selectedDate!.day,
      orElse: () => DateInfo(
        date: _selectedDate!,
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    final List<LocationPoint> pointsToShow = isEditing
        ? appState.editingPoints
        : (appState.activePaths[currentDateInfo.filePath] ?? []);

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDraggingPhotoOver = true),
      onDragExited: (_) => setState(() => _isDraggingPhotoOver = false),
      onDragDone: (detail) {
        setState(() => _isDraggingPhotoOver = false);
        _loadPhotosFromFiles(detail.files.map((f) => File(f.path)).toList());
      },
      child: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                Container(
                  width: _sidebarWidth,
                  color: Theme.of(context).colorScheme.surface,
                  child: _buildSidebar(
                      context, appState, currentDateInfo, pointsToShow),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + details.delta.dx)
                          .clamp(280.0, 800.0);
                    });
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      width: 8,
                      color: Colors.transparent,
                      child: const Center(
                          child: VerticalDivider(width: 1, thickness: 1)),
                    ),
                  ),
                ),
                // Map Panel
                Expanded(
                  child: Stack(
                    children: [
                      _buildMap(context, appState, settings, pointsToShow),

                      // Map mode / Map Layer & Action Menu toolbar
                      Positioned(
                        top: 16,
                        left: _showCalendar ? 350 : 16,
                        child: Row(
                          children: [
                            // Quick Map Layer Switcher (Satellite, Roadmap, OSM)
                            PopupMenuButton<String>(
                              tooltip: 'Change Map Layer',
                              onSelected: (provider) {
                                settings.updateMapProvider(provider);
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'google_satellite',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.satellite_alt, size: 18),
                                      const SizedBox(width: 8),
                                      const Text('Google Satellite'),
                                      if (settings.mapProvider ==
                                          'google_satellite') ...[
                                        const Spacer(),
                                        const Icon(Icons.check,
                                            size: 16, color: Colors.teal),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'bing_satellite',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.satellite, size: 18),
                                      const SizedBox(width: 8),
                                      const Text('Bing Satellite'),
                                      if (settings.mapProvider ==
                                          'bing_satellite') ...[
                                        const Spacer(),
                                        const Icon(Icons.check,
                                            size: 16, color: Colors.teal),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'google_roadmap',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.map, size: 18),
                                      const SizedBox(width: 8),
                                      const Text('Google Roadmap'),
                                      if (settings.mapProvider ==
                                          'google_roadmap') ...[
                                        const Spacer(),
                                        const Icon(Icons.check,
                                            size: 16, color: Colors.teal),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'osm',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.public, size: 18),
                                      const SizedBox(width: 8),
                                      const Text('OpenStreetMap'),
                                      if (settings.mapProvider == 'osm') ...[
                                        const Spacer(),
                                        const Icon(Icons.check,
                                            size: 16, color: Colors.teal),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                              child: Material(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(20),
                                elevation: 2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        settings.mapProvider
                                                .contains('satellite')
                                            ? Icons.satellite_alt
                                            : Icons.map,
                                        size: 16,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        settings.mapProvider ==
                                                'google_satellite'
                                            ? 'Satellite'
                                            : (settings.mapProvider ==
                                                    'bing_satellite'
                                                ? 'Bing Sat'
                                                : (settings.mapProvider ==
                                                        'google_roadmap'
                                                    ? 'Roadmap'
                                                    : 'OSM')),
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold),
                                      ),
                                      const Icon(Icons.arrow_drop_down,
                                          size: 18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),

                            // Single Unified Action Menu Button
                            PopupMenuButton<String>(
                              tooltip: 'Menu',
                              onSelected: (value) async {
                                if (value == 'edit_path') {
                                  appState
                                      .startEditing(currentDateInfo.filePath);
                                } else if (value == 'add_photos') {
                                  final result = await FilePicker.platform
                                      .pickFiles(
                                          allowMultiple: true,
                                          type: FileType.image);
                                  if (result != null && mounted) {
                                    await _loadPhotosFromFiles(result.paths
                                        .whereType<String>()
                                        .map(File.new)
                                        .toList());
                                  }
                                } else if (value == 'add_folder') {
                                  final folderPath = await FilePicker.platform
                                      .getDirectoryPath();
                                  if (folderPath != null && mounted) {
                                    await _loadPhotosFromFiles(
                                        [File(folderPath)]);
                                  }
                                } else if (value == 'clear_photos') {
                                  setState(() {
                                    _photos.clear();
                                    _selectedPhoto = null;
                                    _showPhotoGrid = false;
                                  });
                                }
                              },
                              itemBuilder: (context) => [
                                if (!isEditing &&
                                    currentDateInfo.filePath.isNotEmpty)
                                  const PopupMenuItem(
                                    value: 'edit_path',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit_road,
                                            size: 18, color: Colors.blue),
                                        SizedBox(width: 8),
                                        Text('Edit Path'),
                                      ],
                                    ),
                                  ),
                                const PopupMenuItem(
                                  value: 'add_photos',
                                  child: Row(
                                    children: [
                                      Icon(Icons.add_photo_alternate,
                                          size: 18, color: Colors.purple),
                                      SizedBox(width: 8),
                                      Text('Add Photos'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'add_folder',
                                  child: Row(
                                    children: [
                                      Icon(Icons.create_new_folder,
                                          size: 18, color: Colors.deepPurple),
                                      SizedBox(width: 8),
                                      Text('Add Folder (Recursive)'),
                                    ],
                                  ),
                                ),
                                if (_photos.isNotEmpty) ...[
                                  const PopupMenuDivider(),
                                  const PopupMenuItem(
                                    value: 'clear_photos',
                                    child: Row(
                                      children: [
                                        Icon(Icons.clear_all,
                                            size: 18, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Clear All Photos'),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                              child: Material(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(20),
                                elevation: 2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.menu,
                                          size: 16, color: Colors.white),
                                      const SizedBox(width: 6),
                                      Text(
                                        _photos.isEmpty
                                            ? 'Menu'
                                            : 'Menu (${_photos.length} photos)',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Floating Calendar Overlay
                      if (_showCalendar)
                        Positioned(
                          top: 16,
                          left: 16,
                          child: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(12),
                            shadowColor: Colors.black38,
                            child: SizedBox(
                              width: 320,
                              child: CustomCalendarInline(
                                selectedDate: _selectedDate ?? DateTime.now(),
                                allDates: appState.allDates,
                                photos: _photos,
                                onDateSelected: (date) {
                                  setState(() => _selectedDate = date);
                                  _loadPointsForSelectedDate();
                                },
                                onClose: () =>
                                    setState(() => _showCalendar = false),
                              ),
                            ),
                          ),
                        ),

                      // Save / Cancel Floating Buttons
                      if (isEditing)
                        Positioned(
                          bottom: _photos.isNotEmpty ? 168 : 20,
                          left: 16,
                          child: Row(
                            children: [
                              FloatingActionButton.extended(
                                heroTag: 'save_edit',
                                onPressed: () async {
                                  await appState.saveEditingChanges(timeOffset);
                                  setState(() => _selectedPointIndex = null);
                                  _loadPointsForSelectedDate();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content:
                                              Text('Timeline edits saved.')),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.save),
                                label: const Text('Save Changes'),
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              FloatingActionButton.extended(
                                heroTag: 'cancel_edit',
                                onPressed: () {
                                  appState.cancelEditing();
                                  setState(() {
                                    _selectedPointIndex = null;
                                    _hoveredLatLng = null;
                                    _hoveredProjection = null;
                                  });
                                },
                                icon: const Icon(Icons.cancel),
                                label: const Text('Cancel'),
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                            ],
                          ),
                        ),

                      // Require Shift To Edit / Drag Toggle Button (Bottom-Right, positioned above rotation circle)
                      Positioned(
                        right: 16,
                        bottom: _photos.isNotEmpty ? 160 : 64,
                        child: Tooltip(
                          message: settings.requireShiftToDrag
                              ? 'Hold Shift key to edit/drag points (Prevent Accidental Drag: ON)'
                              : 'Click to require Shift key before editing/dragging points',
                          child: Material(
                            color: settings.requireShiftToDrag
                                ? Colors.deepPurple.shade600
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                            elevation: 3,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () {
                                settings.updateRequireShiftToDrag(
                                    !settings.requireShiftToDrag);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      settings.requireShiftToDrag
                                          ? Icons.lock
                                          : Icons.lock_open_outlined,
                                      size: 15,
                                      color: settings.requireShiftToDrag
                                          ? Colors.white
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurface,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      settings.requireShiftToDrag
                                          ? 'Shift Edit: ON'
                                          : 'Shift Edit: OFF',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: settings.requireShiftToDrag
                                            ? Colors.white
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Photo strip / preview panel
                      if (_photos.isNotEmpty)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: _buildPhotoPanel(
                              context, appState, currentDateInfo, settings),
                        ),
                    ],
                  ),
                ),
              ],
            ),

            // Drag-over overlay
            if (_isDraggingPhotoOver)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withValues(alpha: 0.18),
                      border: Border.all(color: Colors.deepPurple, width: 3),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_photo_alternate,
                            size: 80, color: Colors.deepPurple.shade300),
                        const SizedBox(height: 12),
                        Text('Drop photos here',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(color: Colors.deepPurple)),
                      ],
                    ),
                  ),
                ),
              ),

            // Photo grid overlay
            if (_showPhotoGrid)
              Positioned.fill(
                child: _buildPhotoGrid(
                    context, appState, currentDateInfo, settings),
              ),

            // Import progress overlay
            if (_isImportingPhotos) _buildImportProgressOverlay(context),

            // Saving-to-disk indicator (bottom-right, disappears when done)
            if (_isSaving)
              Positioned(
                right: 16,
                bottom: _photos.isNotEmpty ? 112 : 16,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _isSaving ? 0.55 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 6,
                              offset: Offset(0, 2))
                        ],
                      ),
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.grey),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Photo strip panel (bottom) ───────────────────────────────────────────
  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Photo Panel — strip gallery, selected-photo actions, grid view
  //   • _buildPhotoPanel   : bottom horizontal scroll strip
  //   • _buildSelectedPhotoActions : action bar shown when a photo is tapped
  //   • _buildPhotoGrid    : full-screen grid expand view
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPhotoPanel(BuildContext context, AppStateProvider appState,
      DateInfo currentDateInfo, SettingsProvider settings) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle + header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Icon(Icons.photo_library,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                    '${_currentDatePhotos.length} photo${_currentDatePhotos.length > 1 ? 's' : ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 4),
                Text(
                  '· ${_currentDatePhotos.where((p) => p.gpsLatLng != null).length} with GPS'
                  ' · ${_currentDatePhotos.where((p) => p.addedToTimeline).length} added',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.grid_view, size: 18),
                  tooltip: 'Expand Grid',
                  onPressed: () => setState(() => _showPhotoGrid = true),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Collapse',
                  onPressed: () => setState(() {
                    _selectedPhoto = null;
                  }),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Horizontal scroll strip
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              itemCount: _currentDatePhotos.length,
              itemBuilder: (context, idx) {
                final photo = _currentDatePhotos[idx];
                final isSelected = _selectedPhoto == photo;
                return GestureDetector(
                  onTap: () => setState(() {
                    _selectedPhoto = isSelected ? null : photo;
                    // Pan map to photo location
                    if (!isSelected && photo.gpsLatLng != null) {
                      _animatedMapMove(photo.gpsLatLng!, 15.0);
                    }
                  }),
                  child: Container(
                    width: 80,
                    height: 80,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : (photo.addedToTimeline
                                ? Colors.green
                                : Colors.transparent),
                        width: 2,
                      ),
                    ),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            photo.file,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            cacheWidth: 150,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade800,
                              child: const Icon(Icons.broken_image,
                                  size: 16, color: Colors.white54),
                            ),
                          ),
                        ),
                        // GPS badge
                        if (photo.gpsLatLng != null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: photo.addedToTimeline
                                    ? Colors.green
                                    : Colors.blue,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                photo.addedToTimeline
                                    ? Icons.check
                                    : Icons.gps_fixed,
                                size: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        // File name
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 2),
                            color: Colors.black54,
                            child: Text(
                              photo.filename,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 8),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Selected photo action bar
          if (_selectedPhoto != null)
            _buildSelectedPhotoActions(
                context, appState, currentDateInfo, settings),
        ],
      ),
    );
  }

  // ── Selected photo action row ────────────────────────────────────────────
  Widget _buildSelectedPhotoActions(
      BuildContext context,
      AppStateProvider appState,
      DateInfo currentDateInfo,
      SettingsProvider settings) {
    final photo = _selectedPhoto!;
    final offset = settings.geotagTimezone;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              photo.file,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              cacheWidth: 100,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade800,
                child: const Icon(Icons.broken_image,
                    size: 16, color: Colors.white54),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(photo.filename,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (photo.dateTaken != null)
                  Text(
                    DateFormat('yyyy-MM-dd HH:mm:ss').format(photo.dateTaken!
                        .add(Duration(minutes: (offset * 60).toInt()))),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                if (photo.gpsLatLng != null)
                  Text(
                    'GPS: ${photo.gpsLatLng!.latitude.toStringAsFixed(5)}, '
                    '${photo.gpsLatLng!.longitude.toStringAsFixed(5)}',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.blueAccent),
                  )
                else if (photo.interpolatedLatLng != null)
                  Text(
                    'Interpolated: ${photo.interpolatedLatLng!.latitude.toStringAsFixed(5)}, '
                    '${photo.interpolatedLatLng!.longitude.toStringAsFixed(5)}',
                    style: TextStyle(fontSize: 11, color: Colors.teal.shade400),
                  )
                else
                  const Text('No GPS in EXIF',
                      style: TextStyle(fontSize: 11, color: Colors.orange)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Actions
          if (photo.gpsLatLng != null && !photo.addedToTimeline)
            FilledButton.icon(
              onPressed: () => _addPhotoGpsToTimeline(photo),
              icon: const Icon(Icons.timeline, size: 16),
              label: const Text('Add to Timeline'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.indigo,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
            )
          else if (photo.gpsLatLng == null && photo.interpolatedLatLng != null)
            FilledButton.icon(
              onPressed: () => _applyInterpolatedGeotag(photo),
              icon: const Icon(Icons.pin_drop, size: 16),
              label: const Text('Apply Geotag'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
            )
          else if (photo.addedToTimeline)
            Chip(
              label: const Text('Added ✓',
                  style: TextStyle(fontSize: 11, color: Colors.white)),
              backgroundColor: Colors.green.shade600,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          const SizedBox(width: 8),
          if (photo.assignedLatLng != null)
            OutlinedButton.icon(
              onPressed: () => _animatedMapMove(photo.assignedLatLng!, 16),
              icon: const Icon(Icons.center_focus_strong, size: 16),
              label: const Text('Go to', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              _photos.remove(photo);
              _selectedPhoto = null;
            }),
            tooltip: 'Remove photo',
          ),
        ],
      ),
    );
  }

  // ── Photo grid overlay ───────────────────────────────────────────────────
  Widget _buildPhotoGrid(BuildContext context, AppStateProvider appState,
      DateInfo currentDateInfo, SettingsProvider settings) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.photo_library, color: Colors.white),
                const SizedBox(width: 8),
                Text('${_photos.length} Photos',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(width: 8),
                Text(
                  '${_photos.where((p) => p.gpsLatLng != null).length} with GPS',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const Spacer(),
                // Add all GPS to timeline
                if (_photos
                    .any((p) => p.gpsLatLng != null && !p.addedToTimeline))
                  FilledButton.icon(
                    onPressed: () async {
                      for (final p in _photos) {
                        if (p.gpsLatLng != null && !p.addedToTimeline) {
                          await _addPhotoGpsToTimeline(p);
                        }
                      }
                      setState(() {});
                    },
                    icon: const Icon(Icons.timeline, size: 16),
                    label: const Text('Add All GPS to Timeline'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => setState(() => _showPhotoGrid = false),
                  tooltip: 'Close Grid',
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 1),

          // Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
              ),
              itemCount: _photos.length,
              itemBuilder: (context, idx) {
                final photo = _photos[idx];
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedPhoto = photo;
                      _showPhotoGrid = false;
                    });
                    if (photo.gpsLatLng != null) {
                      _animatedMapMove(photo.gpsLatLng!, 15);
                    }
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(photo.file,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                    color: Colors.grey.shade800,
                                    child: const Icon(Icons.broken_image,
                                        color: Colors.white54),
                                  )),
                        ),
                      ),
                      // Status badge
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: photo.addedToTimeline
                                ? Colors.green
                                : (photo.gpsLatLng != null
                                    ? Colors.blue
                                    : Colors.orange),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            photo.addedToTimeline
                                ? Icons.check
                                : (photo.gpsLatLng != null
                                    ? Icons.gps_fixed
                                    : Icons.gps_off),
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      // Quick Add button on hover
                      if (photo.gpsLatLng != null && !photo.addedToTimeline)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: GestureDetector(
                              onTap: () => _addPhotoGpsToTimeline(photo),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add,
                                      size: 12, color: Colors.white),
                                  SizedBox(width: 2),
                                  Text('Timeline',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 9)),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Timeline clustering — group points into StayPoint / MoveSegment
  //   • _formatDuration     : human-readable duration string
  //   • _clusterTimelineRaw : raw grouping algorithm
  //   • _clusterTimeline    : wrapper that returns typed TimelineItem list
  // ─────────────────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) {
      return '${h}h ${m}m';
    } else {
      return '${m}m';
    }
  }

  List<TimelineItem> _clusterTimelineRaw(
      List<LocationPoint> points, double timezoneOffset) {
    if (points.isEmpty) return [];
    if (points.length < 2) {
      return [
        TimelinePlace(
          points: points,
          startTime: points.first.timestamp,
          endTime: points.first.timestamp,
          center: points.first.latLng,
        )
      ];
    }

    final List<TimelineItem> items = [];
    final double distThreshold =
        TimelineConstants.stayPointDistanceThreshold; // meters
    final Duration timeThreshold = TimelineConstants.stayPointDurationThreshold;

    int i = 0;
    final int n = points.length;

    while (i < n) {
      int j = i + 1;

      while (j < n) {
        final d = GeoUtils.distanceBetween(points[i].latLng, points[j].latLng);
        if (d < distThreshold) {
          j++;
        } else {
          break;
        }
      }

      final duration = points[j - 1].timestamp.difference(points[i].timestamp);
      if (duration >= timeThreshold && (j - i) >= 2) {
        final stayPoints = points.sublist(i, j);
        double latSum = 0;
        double lngSum = 0;
        for (final p in stayPoints) {
          latSum += p.latitude;
          lngSum += p.longitude;
        }
        final center =
            LatLng(latSum / stayPoints.length, lngSum / stayPoints.length);

        items.add(TimelinePlace(
          points: stayPoints,
          startTime: points[i].timestamp,
          endTime: points[j - 1].timestamp,
          center: center,
        ));

        i = j;
      } else {
        int nextStayStart = n;
        for (int m = i + 1; m < n; m++) {
          int nextJ = m + 1;
          while (nextJ < n) {
            final d = GeoUtils.distanceBetween(points[m].latLng,
                nextJ < n ? points[nextJ].latLng : points[m].latLng);
            if (d < distThreshold) {
              nextJ++;
            } else {
              break;
            }
          }
          final nextDur =
              points[nextJ - 1].timestamp.difference(points[m].timestamp);
          if (nextDur >= timeThreshold && (nextJ - m) >= 2) {
            nextStayStart = m;
            break;
          }
        }

        final movePoints = points.sublist(i, nextStayStart);
        double distSum = 0;
        final List<LocationPoint> pathPoints = [];
        if (i > 0) {
          pathPoints.add(points[i - 1]);
        }
        pathPoints.addAll(movePoints);
        if (nextStayStart < n) {
          pathPoints.add(points[nextStayStart]);
        }

        for (int m = 0; m < pathPoints.length - 1; m++) {
          distSum += GeoUtils.distanceBetween(
              pathPoints[m].latLng, pathPoints[m + 1].latLng);
        }

        final startTime =
            (i > 0) ? points[i - 1].timestamp : points[i].timestamp;
        final endTime = (nextStayStart < n)
            ? points[nextStayStart].timestamp
            : points[nextStayStart - 1].timestamp;

        items.add(TimelinePath(
          points: pathPoints,
          startTime: startTime,
          endTime: endTime,
          distance: distSum,
        ));

        i = nextStayStart;
      }
    }

    return items;
  }

  List<TimelineItem> _clusterTimeline(
      List<LocationPoint> points, double timezoneOffset) {
    final List<TimelineItem> rawItems =
        _clusterTimelineRaw(points, timezoneOffset);

    if (_previousDayLastStayPoint != null && _selectedDate != null) {
      final currentDayMidnight = DateTime.utc(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        0,
        0,
        0,
      );

      if (rawItems.isNotEmpty) {
        final firstItem = rawItems.first;
        if (firstItem.startTime.difference(currentDayMidnight).inMinutes > 1) {
          final stayPoints = [
            LocationPoint(
              latitude: _previousDayLastStayPoint!.latitude,
              longitude: _previousDayLastStayPoint!.longitude,
              timestamp: currentDayMidnight,
            ),
            LocationPoint(
              latitude: _previousDayLastStayPoint!.latitude,
              longitude: _previousDayLastStayPoint!.longitude,
              timestamp: firstItem.startTime,
            ),
          ];

          final initialStay = TimelinePlace(
            points: stayPoints,
            startTime: currentDayMidnight,
            endTime: firstItem.startTime,
            center: LatLng(_previousDayLastStayPoint!.latitude,
                _previousDayLastStayPoint!.longitude),
          );

          rawItems.insert(0, initialStay);
        }
      } else {
        final currentDayEnd = currentDayMidnight.add(const Duration(hours: 24));
        final stayPoints = [
          LocationPoint(
            latitude: _previousDayLastStayPoint!.latitude,
            longitude: _previousDayLastStayPoint!.longitude,
            timestamp: currentDayMidnight,
          ),
          LocationPoint(
            latitude: _previousDayLastStayPoint!.latitude,
            longitude: _previousDayLastStayPoint!.longitude,
            timestamp: currentDayEnd,
          ),
        ];

        final initialStay = TimelinePlace(
          points: stayPoints,
          startTime: currentDayMidnight,
          endTime: currentDayEnd,
          center: LatLng(_previousDayLastStayPoint!.latitude,
              _previousDayLastStayPoint!.longitude),
        );

        rawItems.add(initialStay);
      }
    }

    return rawItems;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Timeline item renderer — stay-point card, move-segment card,
  //          transit icons, road-snap, clipboard copy helpers
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildTimelineItem(
      BuildContext context,
      List<TimelineItem> allItems,
      int index,
      double timezoneOffset,
      bool isSelected,
      bool isFirst,
      bool isLast) {
    final item = allItems[index];
    const blueAxis = TimelineConstants.timelineAxisColor;
    final hasAnySelection = _selectedTimelineItemIndex != null;
    final lineActiveColor = hasAnySelection
        ? (isSelected ? blueAxis : blueAxis.withValues(alpha: 0.25))
        : blueAxis;
    // Col 1: place icon / expand icon
    const iconColWidth = TimelineConstants.iconColumnWidth;
    // Col 2: continuous blue line (with dot at stay points)
    const lineColWidth = TimelineConstants.lineColumnWidth;

    if (item is TimelinePlace) {
      final startTime = _formatPointTime(item.startTime, timezoneOffset);
      final endTime = _formatPointTime(item.endTime, timezoneOffset);
      final durationStr = _formatDuration(item.duration);
      final coordStr =
          '${item.center.latitude.toStringAsFixed(5)}, ${item.center.longitude.toStringAsFixed(5)}';

      Widget tileWidget = _TimelineTileWrapper(
        isSelected: isSelected,
        onTap: () {
          setState(() {
            if (_selectedTimelineItemIndex == index) {
              _selectedTimelineItemIndex = null;
            } else {
              _selectedTimelineItemIndex = index;
              _animatedMapMove(item.center, 16.5);
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Col 1: Brown place icon ───────────────────────────
                SizedBox(
                  width: iconColWidth,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: TimelineConstants.stayPointIconColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.place,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                // ── Col 2: Continuous blue line + large dot at this point ──
                SizedBox(
                  width: lineColWidth,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Equal-height top and bottom line segments
                      Positioned.fill(
                        child: Column(
                          children: [
                            Expanded(
                              child: Container(
                                width: TimelineConstants.timelineLineThickness,
                                color: isFirst
                                    ? Colors.transparent
                                    : lineActiveColor,
                              ),
                            ),
                            Expanded(
                              child: Container(
                                width: TimelineConstants.timelineLineThickness,
                                color: isLast
                                    ? Colors.transparent
                                    : lineActiveColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Large circle dot at this stay point
                      Container(
                        width: TimelineConstants.timelineDotDiameter,
                        height: TimelineConstants.timelineDotDiameter,
                        decoration: BoxDecoration(
                          color: lineActiveColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // ── Content ───────────────────────────────────────────
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Place name box
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            'Place (${item.points.length} pts)',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(Icons.arrow_drop_down,
                                            size: 18),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  // Coordinates
                                  Text(
                                    coordStr,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  // 2 Separate Time Boxes (Clicking directly opens TimePicker, NO middle popup dialog!)
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      // 1. Start Time Box
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () async {
                                          final appState =
                                              context.read<AppStateProvider>();
                                          final dateInfo =
                                              _currentDateInfo(appState);
                                          final tod = await showTimePicker(
                                            context: context,
                                            initialTime: TimeOfDay.fromDateTime(
                                                item.startTime.toLocal()),
                                          );
                                          if (tod != null) {
                                            final startLocal =
                                                item.startTime.toLocal();
                                            final newStartLocal = DateTime(
                                              startLocal.year,
                                              startLocal.month,
                                              startLocal.day,
                                              tod.hour,
                                              tod.minute,
                                              startLocal.second,
                                            );
                                            _updatePlaceTimeBounds(
                                              item,
                                              newStartLocal,
                                              item.endTime.toLocal(),
                                              appState,
                                              dateInfo,
                                            );
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer
                                                .withValues(alpha: 0.45),
                                            borderRadius:
                                                BorderRadius.circular(5),
                                            border: Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.35),
                                              width: 1,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.access_time,
                                                  size: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary),
                                              const SizedBox(width: 3),
                                              Text(
                                                startTime,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const Text('–',
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold)),
                                      // 2. End Time Box
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () async {
                                          final appState =
                                              context.read<AppStateProvider>();
                                          final dateInfo =
                                              _currentDateInfo(appState);
                                          final tod = await showTimePicker(
                                            context: context,
                                            initialTime: TimeOfDay.fromDateTime(
                                                item.endTime.toLocal()),
                                          );
                                          if (tod != null) {
                                            final endLocal =
                                                item.endTime.toLocal();
                                            final newEndLocal = DateTime(
                                              endLocal.year,
                                              endLocal.month,
                                              endLocal.day,
                                              tod.hour,
                                              tod.minute,
                                              endLocal.second,
                                            );
                                            if (newEndLocal.isBefore(
                                                item.startTime.toLocal())) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                      content: Text(
                                                          'End time cannot be earlier than start time.')),
                                                );
                                              }
                                              return;
                                            }
                                            _updatePlaceTimeBounds(
                                              item,
                                              item.startTime.toLocal(),
                                              newEndLocal,
                                              appState,
                                              dateInfo,
                                            );
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer
                                                .withValues(alpha: 0.45),
                                            borderRadius:
                                                BorderRadius.circular(5),
                                            border: Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.35),
                                              width: 1,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.access_time,
                                                  size: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary),
                                              const SizedBox(width: 3),
                                              Text(
                                                endTime,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '($durationStr)',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Time + more menu
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  startTime,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                PopupMenuButton<String>(
                                  icon: Icon(Icons.more_vert,
                                      size: 18,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                                  padding: EdgeInsets.zero,
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                      value: 'copy_json',
                                      child: Row(
                                        children: [
                                          Icon(Icons.copy, size: 18),
                                          SizedBox(width: 8),
                                          Text('Copy Segment JSON'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'copy_json_neighbors',
                                      child: Row(
                                        children: [
                                          Icon(Icons.copy_all, size: 18),
                                          SizedBox(width: 8),
                                          Text('Copy JSON with Neighbors'),
                                        ],
                                      ),
                                    ),
                                  ],
                                  onSelected: (val) {
                                    if (val == 'copy_json') {
                                      _copySegmentJson(context, item);
                                    } else if (val == 'copy_json_neighbors') {
                                      _copyJsonWithNeighbors(
                                          context, allItems, index);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (item.geotaggedPhotos.isNotEmpty ||
                            item.ungeotaggedPhotos.isNotEmpty)
                          _buildTimelinePhotoRows(context, item, index),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return tileWidget;
    } else if (item is TimelinePath) {
      final durationStr = _formatDuration(item.duration);
      final distStr = item.distance < 1000
          ? '${item.distance.toStringAsFixed(0)} m'
          : '${(item.distance / 1000).toStringAsFixed(2)} km';

      Widget tileWidget = _TimelineTileWrapper(
        isSelected: isSelected,
        onTap: () {
          setState(() {
            if (_selectedTimelineItemIndex == index) {
              _selectedTimelineItemIndex = null;
            } else {
              _selectedTimelineItemIndex = index;
            }
          });
          if (_selectedTimelineItemIndex == index && item.points.isNotEmpty) {
            final bounds = LatLngBounds.fromPoints(
              item.points.map((p) => p.latLng).toList(),
            );
            _animatedFitBounds(bounds);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Col 1: Expand/collapse icon (same column as place icon) ──
                SizedBox(
                  width: iconColWidth,
                  child: Center(
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Icon(
                        Icons.unfold_more,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                // ── Col 2: Continuous blue line (no dot for move segment) ──
                SizedBox(
                  width: lineColWidth,
                  child: Center(
                    child: Container(
                      width: TimelineConstants.timelineLineThickness,
                      color: lineActiveColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // ── Content ───────────────────────────────────────────
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _buildTransitIcons(item),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$durationStr  ·  $distStr',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            if (_unsnappedSegmentBackups.containsKey(
                                _getSegmentKey(
                                    item.startTime, item.endTime))) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.undo,
                                    size: 16, color: Colors.blue),
                                tooltip: 'Undo Edit (Session)',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  final appState =
                                      context.read<AppStateProvider>();
                                  final dateInfo = _currentDateInfo(appState);
                                  _undoSnapSegment(item, appState, dateInfo);
                                },
                              ),
                            ],
                            const SizedBox(width: 4),
                            PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert,
                                  size: 18,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                              padding: EdgeInsets.zero,
                              itemBuilder: (context) {
                                final hasBackup = _unsnappedSegmentBackups
                                    .containsKey(_getSegmentKey(
                                        item.startTime, item.endTime));
                                return [
                                  if (hasBackup)
                                    const PopupMenuItem(
                                      value: 'undo_snap',
                                      child: Row(
                                        children: [
                                          Icon(Icons.undo,
                                              size: 18, color: Colors.blue),
                                          SizedBox(width: 8),
                                          Text('Undo Edit (Session)'),
                                        ],
                                      ),
                                    ),
                                  const PopupMenuItem(
                                    value: 'snap_osrm',
                                    child: Row(
                                      children: [
                                        Icon(Icons.alt_route, size: 18),
                                        SizedBox(width: 8),
                                        Text('Snap Segment to Roads'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'restore_original',
                                    child: Row(
                                      children: [
                                        Icon(Icons.restore,
                                            size: 18, color: Colors.orange),
                                        SizedBox(width: 8),
                                        Text('Restore to Original State'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'copy_json',
                                    child: Row(
                                      children: [
                                        Icon(Icons.copy, size: 18),
                                        SizedBox(width: 8),
                                        Text('Copy Segment JSON'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'copy_json_neighbors',
                                    child: Row(
                                      children: [
                                        Icon(Icons.copy_all, size: 18),
                                        SizedBox(width: 8),
                                        Text('Copy JSON with Neighbors'),
                                      ],
                                    ),
                                  ),
                                ];
                              },
                              onSelected: (val) async {
                                if (val == 'undo_snap') {
                                  final appState =
                                      context.read<AppStateProvider>();
                                  final dateInfo = _currentDateInfo(appState);
                                  _undoSnapSegment(item, appState, dateInfo);
                                } else if (val == 'restore_original') {
                                  final appState =
                                      context.read<AppStateProvider>();
                                  final dateInfo = _currentDateInfo(appState);
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text(
                                          'Restore Segment to Original'),
                                      content: const Text(
                                        'Restore ONLY this road segment to its original raw backup state? All other roads for this day will remain untouched.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Restore Segment'),
                                        ),
                                      ],
                                    ),
                                  );

                                  if (confirm == true && context.mounted) {
                                    _restoreSegmentToOriginal(
                                        item, appState, dateInfo);
                                  }
                                } else if (val == 'snap_osrm') {
                                  final appState =
                                      context.read<AppStateProvider>();
                                  final dateInfo = appState.allDates.firstWhere(
                                    (d) =>
                                        _selectedDate != null &&
                                        d.date.year == _selectedDate!.year &&
                                        d.date.month == _selectedDate!.month &&
                                        d.date.day == _selectedDate!.day,
                                    orElse: () => DateInfo(
                                      date: _selectedDate ?? DateTime.now(),
                                      pointCount: 0,
                                      filePath: '',
                                      distance: 0.0,
                                      state: 'original',
                                      source: 'merge',
                                      hasTimelineBackup: false,
                                      hasGpxBackup: false,
                                    ),
                                  );
                                  final dayPoints =
                                      appState.activePaths[dateInfo.filePath] ??
                                          [];
                                  _snapSegmentToRoads(context, appState,
                                      dateInfo, dayPoints, item);
                                } else if (val == 'copy_json') {
                                  _copySegmentJson(context, item);
                                } else if (val == 'copy_json_neighbors') {
                                  _copyJsonWithNeighbors(
                                      context, allItems, index);
                                }
                              },
                            ),
                          ],
                        ),
                        if (item.geotaggedPhotos.isNotEmpty ||
                            item.ungeotaggedPhotos.isNotEmpty)
                          _buildTimelinePhotoRows(context, item, index),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return tileWidget;
    }
    return const SizedBox.shrink();
  }

  List<String> _getTransitModes(TimelinePath path) {
    final List<String> modes = [];
    String? lastMode;

    for (final p in path.points) {
      final mode = p.activityType;
      if (mode != null && mode.isNotEmpty) {
        if (mode != lastMode) {
          modes.add(mode);
          lastMode = mode;
        }
      }
    }

    if (modes.isEmpty) {
      final durationSec = path.duration.inSeconds;
      final distKm = path.distance / 1000.0;
      if (durationSec > 0 && distKm > 0) {
        final speedKmH = (distKm / durationSec) * 3600.0;
        if (speedKmH <= 7.0) {
          modes.add('WALKING');
        } else if (speedKmH <= 15.0) {
          modes.add('CYCLING');
        } else if (speedKmH <= 75.0) {
          modes.add('MOTORCYCLING');
        } else {
          modes.add('IN_VEHICLE');
        }
      } else {
        modes.add('WALKING');
      }
    }

    return modes;
  }

  IconData _getTransitIcon(String mode) {
    final norm = mode.toUpperCase();
    if (norm.contains('WALK') ||
        norm.contains('FOOT') ||
        norm.contains('RUN')) {
      return Icons.directions_walk;
    }
    if (norm.contains('BIKE') ||
        norm.contains('BICYCLE') ||
        norm.contains('CYCLE')) {
      return Icons.directions_bike;
    }
    if (norm.contains('BUS')) {
      return Icons.directions_bus;
    }
    if (norm.contains('TRAIN') ||
        norm.contains('SUBWAY') ||
        norm.contains('RAIL')) {
      return Icons.directions_railway;
    }
    if (norm.contains('FLY') || norm.contains('AIR')) {
      return Icons.local_airport;
    }
    if (norm.contains('SAIL') ||
        norm.contains('BOAT') ||
        norm.contains('SHIP')) {
      return Icons.directions_boat;
    }
    if (norm.contains('CAR') ||
        norm.contains('DRIVE') ||
        norm.contains('VEHICLE')) {
      return Icons.directions_car;
    }
    return Icons.motorcycle;
  }

  List<Widget> _buildTransitIcons(TimelinePath path) {
    final modes = _getTransitModes(path);
    final List<Widget> widgets = [];

    for (int i = 0; i < modes.length; i++) {
      final iconData = _getTransitIcon(modes[i]);
      widgets.add(
        Icon(iconData, size: 20, color: const Color(0xFF555555)),
      );
      if (i < modes.length - 1) {
        widgets.add(const SizedBox(width: 4));
        widgets.add(
          const Icon(Icons.chevron_right, size: 16, color: Color(0xFF999999)),
        );
        widgets.add(const SizedBox(width: 4));
      }
    }

    return widgets;
  }

  String _getSegmentKey(DateTime start, DateTime end) =>
      '${start.millisecondsSinceEpoch}_${end.millisecondsSinceEpoch}';

  Future<void> _snapSegmentToRoads(
      BuildContext context,
      AppStateProvider appState,
      DateInfo dateInfo,
      List<LocationPoint> dayPoints,
      TimelinePath segment) async {
    if (segment.points.isEmpty) return;

    final segmentKey = _getSegmentKey(segment.startTime, segment.endTime);
    _unsnappedSegmentBackups[segmentKey] =
        List<LocationPoint>.from(segment.points);

    final settings = context.read<SettingsProvider>();
    final useGoogle = settings.routingProvider == 'google';
    final googleApiKey = settings.googleMapsApiKey;

    if (useGoogle && googleApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please configure your Google Maps API Key in Settings.')),
      );
      return;
    }

    final originalPoints = segment.points;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(useGoogle
                    ? 'Routing segment with Google Roads API...'
                    : 'Routing segment with OSRM...'),
              ],
            ),
          ),
        ),
      ),
    );

    final List<LocationPoint> newPoints = [];
    bool routingSuccess = true;

    if (useGoogle) {
      final List<Map<String, dynamic>> snappedPoints = [];
      // Google Roads API snapToRoads accepts max 100 points per request.
      // Chunk to handle longer paths robustly.
      for (int start = 0; start < originalPoints.length; start += 99) {
        final end = (start + 100 < originalPoints.length)
            ? start + 100
            : originalPoints.length;
        final chunk = originalPoints.sublist(start, end);
        final pathString =
            chunk.map((p) => '${p.latitude},${p.longitude}').join('|');

        final url =
            'https://roads.googleapis.com/v1/snapToRoads?path=$pathString&interpolate=true&key=$googleApiKey';

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close();
          if (response.statusCode == 200) {
            final responseBody = await response.transform(utf8.decoder).join();
            final data = jsonDecode(responseBody);
            if (data['snappedPoints'] != null) {
              final List chunkSnapped = data['snappedPoints'];
              for (final s in chunkSnapped) {
                final origIdx = s['originalIndex'] as int?;
                final adjustedSnapped = Map<String, dynamic>.from(s);
                if (origIdx != null) {
                  adjustedSnapped['originalIndex'] = origIdx + start;
                }
                snappedPoints.add(adjustedSnapped);
              }
            }
          } else {
            routingSuccess = false;
            debugPrint(
                'Google Roads API error: Status code ${response.statusCode}');
          }
        } catch (e) {
          routingSuccess = false;
          debugPrint('Google Roads API request failed: $e');
        } finally {
          client.close();
        }
      }

      if (routingSuccess && snappedPoints.isNotEmpty) {
        // Interpolate timestamps precisely for snapped and interpolated points
        for (int k = 0; k < snappedPoints.length; k++) {
          final s = snappedPoints[k];
          final lat = s['location']['latitude'] as double;
          final lng = s['location']['longitude'] as double;
          final origIdx = s['originalIndex'] as int?;

          DateTime timestamp;
          if (origIdx != null &&
              origIdx >= 0 &&
              origIdx < originalPoints.length) {
            timestamp = originalPoints[origIdx].timestamp;
          } else {
            // Find preceding and succeeding original index coordinates to interpolate between
            int? prevOrigIdx;
            int? nextOrigIdx;

            for (int prev = k - 1; prev >= 0; prev--) {
              if (snappedPoints[prev]['originalIndex'] != null) {
                prevOrigIdx = snappedPoints[prev]['originalIndex'] as int;
                break;
              }
            }
            for (int next = k + 1; next < snappedPoints.length; next++) {
              if (snappedPoints[next]['originalIndex'] != null) {
                nextOrigIdx = snappedPoints[next]['originalIndex'] as int;
                break;
              }
            }

            if (prevOrigIdx != null && nextOrigIdx != null) {
              final startTime = originalPoints[prevOrigIdx].timestamp;
              final endTime = originalPoints[nextOrigIdx].timestamp;

              int interpCount = 0;
              int myInterpIndex = 0;
              for (int m = k - 1; m >= 0; m--) {
                if (snappedPoints[m]['originalIndex'] != null) break;
                myInterpIndex++;
              }
              for (int m = k + 1; m < snappedPoints.length; m++) {
                if (snappedPoints[m]['originalIndex'] != null) break;
                interpCount++;
              }
              interpCount += myInterpIndex + 1;

              final ratio = (myInterpIndex + 1) / (interpCount + 1);
              timestamp = startTime.add(endTime.difference(startTime) * ratio);
            } else if (prevOrigIdx != null) {
              timestamp = originalPoints[prevOrigIdx].timestamp;
            } else if (nextOrigIdx != null) {
              timestamp = originalPoints[nextOrigIdx].timestamp;
            } else {
              final totalDuration =
                  segment.endTime.difference(segment.startTime);
              timestamp = segment.startTime
                  .add(totalDuration * (k / (snappedPoints.length - 1)));
            }
          }

          newPoints.add(LocationPoint(
            latitude: lat,
            longitude: lng,
            timestamp: timestamp,
            activityType: segment.points.isNotEmpty
                ? segment.points.first.activityType
                : 'MOTORCYCLING',
          ));
        }
      }
    } else {
      // OSRM Map Matching API (/match/v1/) passing ALL segment points
      final osrmProfile = settings.osrmProfile;
      List<LatLng> routedCoords = [];
      final client = HttpClient();

      try {
        // Chunk points in batches of 90 points (with 1 point overlap)
        const int chunkSize = 90;
        for (int start = 0;
            start < originalPoints.length;
            start += (chunkSize - 1)) {
          final end = (start + chunkSize < originalPoints.length)
              ? start + chunkSize
              : originalPoints.length;
          final chunk = originalPoints.sublist(start, end);
          if (chunk.isEmpty) break;

          final coordsString =
              chunk.map((p) => '${p.longitude},${p.latitude}').join(';');

          // Primary: OSRM Map Matching Service (/match/v1/)
          final matchUrl =
              'https://router.project-osrm.org/match/v1/$osrmProfile/$coordsString?overview=full&geometries=geojson';

          final request = await client.getUrl(Uri.parse(matchUrl));
          final response = await request.close();
          bool matchOk = false;

          if (response.statusCode == 200) {
            final responseBody = await response.transform(utf8.decoder).join();
            final data = jsonDecode(responseBody);
            if (data['matchings'] != null &&
                (data['matchings'] as List).isNotEmpty) {
              matchOk = true;
              for (final matchItem in data['matchings']) {
                final geometry = matchItem['geometry'];
                if (geometry != null && geometry['coordinates'] != null) {
                  final coordinates = geometry['coordinates'] as List;
                  final chunkCoords = coordinates.map((coord) {
                    final lng = (coord[0] as num).toDouble();
                    final lat = (coord[1] as num).toDouble();
                    return LatLng(lat, lng);
                  }).toList();
                  routedCoords.addAll(chunkCoords);
                }
              }
            }
          }

          // Fallback if match fails on sparse points: OSRM Route (/route/v1/)
          if (!matchOk) {
            final routeUrl =
                'https://router.project-osrm.org/route/v1/$osrmProfile/$coordsString?overview=full&geometries=geojson';
            final routeReq = await client.getUrl(Uri.parse(routeUrl));
            final routeRes = await routeReq.close();
            if (routeRes.statusCode == 200) {
              final routeBody =
                  await routeRes.transform(utf8.decoder).join();
              final routeData = jsonDecode(routeBody);
              if (routeData['routes'] != null &&
                  (routeData['routes'] as List).isNotEmpty) {
                final geometry = routeData['routes'][0]['geometry'];
                if (geometry != null && geometry['coordinates'] != null) {
                  final coordinates = geometry['coordinates'] as List;
                  final chunkCoords = coordinates.map((coord) {
                    final lng = (coord[0] as num).toDouble();
                    final lat = (coord[1] as num).toDouble();
                    return LatLng(lat, lng);
                  }).toList();
                  routedCoords.addAll(chunkCoords);
                }
              }
            }
          }

          if (end == originalPoints.length) break;
        }
      } catch (e) {
        routingSuccess = false;
        debugPrint('OSRM Map Matching failed: $e');
      } finally {
        client.close();
      }

      if (routingSuccess && routedCoords.isNotEmpty) {
        final List<double> cumulativeDistances = [0.0];
        double totalDist = 0.0;
        for (int k = 0; k < routedCoords.length - 1; k++) {
          final d =
              GeoUtils.distanceBetween(routedCoords[k], routedCoords[k + 1]);
          totalDist += d;
          cumulativeDistances.add(totalDist);
        }

        final totalDuration = segment.endTime.difference(segment.startTime);
        for (int k = 0; k < routedCoords.length; k++) {
          final ratio = totalDist > 0
              ? (cumulativeDistances[k] / totalDist)
              : (k / (routedCoords.length - 1));
          final timestamp = segment.startTime.add(totalDuration * ratio);
          newPoints.add(LocationPoint(
            latitude: routedCoords[k].latitude,
            longitude: routedCoords[k].longitude,
            timestamp: timestamp,
            activityType: segment.points.isNotEmpty
                ? segment.points.first.activityType
                : 'MOTORCYCLING',
          ));
        }
      }
    }

    // Dismiss loading dialog
    if (context.mounted) {
      Navigator.of(context).pop();
    }

    if (newPoints.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Failed to route segment using ${useGoogle ? 'Google Roads API' : 'OSRM'}.')),
        );
      }
      return;
    }

    final List<LocationPoint> updatedPoints = List.from(dayPoints);
    final firstIdx = updatedPoints.indexOf(segment.points.first);
    final lastIdx = updatedPoints.indexOf(segment.points.last);

    if (firstIdx >= 0 && lastIdx >= firstIdx) {
      updatedPoints.removeRange(firstIdx, lastIdx + 1);
      updatedPoints.insertAll(firstIdx, newPoints);
    } else {
      updatedPoints.addAll(newPoints);
    }

    // Update in-memory state IMMEDIATELY (0ms UI lag!)
    final tz = settings.geotagTimezone.toDouble();
    setState(() {
      appState.activePaths[dateInfo.filePath] = updatedPoints;
      _assignPhotosToTimelineItems(updatedPoints, tz);
    });

    // Save to disk asynchronously in background without blocking UI
    appState.saveListPoints(dateInfo, updatedPoints);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Segment successfully snapped to roads!')),
      );
    }
  }

  Future<void> _undoSnapSegment(TimelinePath segment, AppStateProvider appState,
      DateInfo dateInfo) async {
    final segmentKey = _getSegmentKey(segment.startTime, segment.endTime);
    final originalBackup = _unsnappedSegmentBackups[segmentKey];
    if (originalBackup == null) return;

    final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
    final updated = List<LocationPoint>.from(dayPoints);

    // Remove points within segment time bounds
    updated.removeWhere((p) =>
        p.timestamp
            .isAfter(segment.startTime.subtract(const Duration(seconds: 1))) &&
        p.timestamp.isBefore(segment.endTime.add(const Duration(seconds: 1))));

    // Find insertion index
    int insertIdx =
        updated.indexWhere((p) => p.timestamp.isAfter(segment.startTime));
    if (insertIdx == -1) {
      insertIdx = updated.length;
    }
    updated.insertAll(insertIdx, originalBackup);

    // Update in-memory state IMMEDIATELY (0ms UI lag!)
    final settings = context.read<SettingsProvider>();
    final tz = settings.geotagTimezone.toDouble();
    setState(() {
      appState.activePaths[dateInfo.filePath] = updated;
      _unsnappedSegmentBackups.remove(segmentKey);
      _assignPhotosToTimelineItems(updated, tz);
    });

    // Save to disk asynchronously in background without blocking UI
    appState.saveListPoints(dateInfo, updated);
  }

  Future<void> _restoreSegmentToOriginal(TimelinePath segment,
      AppStateProvider appState, DateInfo dateInfo) async {
    final settings = context.read<SettingsProvider>();
    final tz = settings.geotagTimezone.toDouble();
    final originalDir =
        await appState.getAppTimelinesDirectoryPath(active: false);
    final dateStr = DateFormat('yyyy-MM-dd').format(dateInfo.date);

    File? origFile = File(path.join(originalDir, '${dateStr}_timeline.json'));
    if (!await origFile.exists()) {
      origFile = File(path.join(originalDir, '${dateStr}_gpx.json'));
    }
    if (!await origFile.exists()) {
      origFile = File(path.join(originalDir, '$dateStr.json'));
    }

    if (!await origFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No original backup file found for this date.')),
        );
      }
      return;
    }

    try {
      final content = await origFile.readAsString();
      final rawOriginalPoints = LocationPoint.parseAnyJson(jsonDecode(content));

      final startTimeBoundary =
          segment.startTime.subtract(const Duration(seconds: 1));
      final endTimeBoundary = segment.endTime.add(const Duration(seconds: 1));

      final origSegmentPoints = rawOriginalPoints
          .where((p) =>
              !p.timestamp.isBefore(startTimeBoundary) &&
              !p.timestamp.isAfter(endTimeBoundary))
          .toList();

      if (origSegmentPoints.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No original points found for this segment.')),
          );
        }
        return;
      }

      final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
      final updated = List<LocationPoint>.from(dayPoints);

      updated.removeWhere((p) =>
          !p.timestamp.isBefore(startTimeBoundary) &&
          !p.timestamp.isAfter(endTimeBoundary));

      int insertIdx =
          updated.indexWhere((p) => p.timestamp.isAfter(segment.startTime));
      if (insertIdx == -1) {
        insertIdx = updated.length;
      }
      updated.insertAll(insertIdx, origSegmentPoints);

      final segmentKey = _getSegmentKey(segment.startTime, segment.endTime);

      // Update in-memory state IMMEDIATELY (0ms UI lag!)
      setState(() {
        appState.activePaths[dateInfo.filePath] = updated;
        _unsnappedSegmentBackups.remove(segmentKey);
        _assignPhotosToTimelineItems(updated, tz);
      });

      // Save to disk asynchronously in background without blocking UI
      appState.saveListPoints(dateInfo, updated);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Road segment restored to original raw state.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to restore segment: $e')),
        );
      }
    }
  }

  Future<void> _updatePlaceTimeBounds(TimelinePlace place, DateTime newStart,
      DateTime newEnd, AppStateProvider appState, DateInfo dateInfo) async {
    final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
    if (dayPoints.isEmpty || place.points.isEmpty) return;

    final updated = List<LocationPoint>.from(dayPoints);
    final placePts = place.points;
    final origStart = place.startTime;
    final origEnd = place.endTime;

    // Save adjacent path segments for session Undo
    final settings = context.read<SettingsProvider>();
    final timelineItems =
        _clusterTimeline(dayPoints, settings.geotagTimezone.toDouble());
    final placeIdx =
        timelineItems.indexWhere((t) => t is TimelinePlace && t == place);
    if (placeIdx != -1) {
      if (placeIdx - 1 >= 0 && timelineItems[placeIdx - 1] is TimelinePath) {
        final seg = timelineItems[placeIdx - 1] as TimelinePath;
        final key = _getSegmentKey(seg.startTime, seg.endTime);
        _unsnappedSegmentBackups.putIfAbsent(
            key, () => List<LocationPoint>.from(seg.points));
      }
      if (placeIdx + 1 < timelineItems.length &&
          timelineItems[placeIdx + 1] is TimelinePath) {
        final seg = timelineItems[placeIdx + 1] as TimelinePath;
        final key = _getSegmentKey(seg.startTime, seg.endTime);
        _unsnappedSegmentBackups.putIfAbsent(
            key, () => List<LocationPoint>.from(seg.points));
      }
    }

    final totalOldDuration = origEnd.difference(origStart).inMilliseconds;
    final totalNewDuration = newEnd.difference(newStart).inMilliseconds;

    for (int i = 0; i < updated.length; i++) {
      final p = updated[i];
      if (placePts.contains(p)) {
        final elapsed = p.timestamp.difference(origStart).inMilliseconds;
        final ratio = totalOldDuration > 0
            ? (elapsed / totalOldDuration).clamp(0.0, 1.0)
            : 0.0;
        final newTimestamp = newStart
            .add(Duration(milliseconds: (totalNewDuration * ratio).round()));
        updated[i] = LocationPoint(
          latitude: p.latitude,
          longitude: p.longitude,
          timestamp: newTimestamp,
        );
      }
    }

    updated.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Update in-memory state IMMEDIATELY (0ms UI lag!)
    final tz = settings.geotagTimezone.toDouble();
    setState(() {
      appState.activePaths[dateInfo.filePath] = updated;
      _assignPhotosToTimelineItems(updated, tz);
    });

    // Save to disk asynchronously in background without blocking UI
    appState.saveListPoints(dateInfo, updated);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Place time range updated to ${DateFormat('HH:mm:ss').format(newStart.toLocal())} – ${DateFormat('HH:mm:ss').format(newEnd.toLocal())}'),
        ),
      );
    }
  }

  void _copyToClipboard(
      BuildContext context, String text, String successMessage) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(successMessage)),
    );
  }

  Map<String, dynamic> _pointToTimelineJson(LocationPoint p) {
    return {
      'point': '${p.latitude}°, ${p.longitude}°',
      'time': p.timestamp.toUtc().toIso8601String(),
    };
  }

  void _copySegmentJson(BuildContext context, TimelineItem item) {
    final pointsJson = item is TimelinePlace
        ? item.points.map(_pointToTimelineJson).toList()
        : (item as TimelinePath).points.map(_pointToTimelineJson).toList();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(pointsJson);
    _copyToClipboard(context, jsonStr, 'Segment JSON copied to clipboard!');
  }

  void _copyJsonWithNeighbors(
      BuildContext context, List<TimelineItem> allItems, int currentIndex) {
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = TextEditingController(text: '2');
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Copy JSON with Neighbors'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Enter number of neighboring segments to include before & after:'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Number of neighbors',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final neighbors = int.tryParse(ctrl.text.trim()) ?? 2;
              Navigator.of(dialogCtx).pop();

              final start =
                  (currentIndex - neighbors).clamp(0, allItems.length - 1);
              final end =
                  (currentIndex + neighbors).clamp(0, allItems.length - 1);

              final List<Map<String, dynamic>> output = [];
              for (int i = start; i <= end; i++) {
                final item = allItems[i];
                final isCurrent = i == currentIndex;

                final bool isPlace = item is TimelinePlace;
                final String type = isPlace ? 'stay_point' : 'move_segment';
                final List<LocationPoint> pts =
                    isPlace ? item.points : (item as TimelinePath).points;

                final List<Map<String, dynamic>> ptsJson = pts.isNotEmpty
                    ? pts.map(_pointToTimelineJson).toList()
                    : (isPlace
                        ? [
                            {
                              'point':
                                  '${item.center.latitude}°, ${item.center.longitude}°',
                              'time': item.startTime.toUtc().toIso8601String(),
                            }
                          ]
                        : []);

                output.add({
                  'segmentIndex': i,
                  'isTargetSegment': isCurrent,
                  'type': type,
                  'startTime': item.startTime.toUtc().toIso8601String(),
                  'endTime': item.endTime.toUtc().toIso8601String(),
                  'points': ptsJson,
                });
              }

              final jsonStr =
                  const JsonEncoder.withIndent('  ').convert(output);
              Clipboard.setData(ClipboardData(text: jsonStr));
              messenger.showSnackBar(
                const SnackBar(
                    content: Text('JSON with neighbors copied to clipboard!')),
              );
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}

class _TimelineTileWrapper extends StatefulWidget {
  final Widget child;
  final bool isSelected;
  final VoidCallback onTap;

  const _TimelineTileWrapper({
    required this.child,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_TimelineTileWrapper> createState() => _TimelineTileWrapperState();
}

class _TimelineTileWrapperState extends State<_TimelineTileWrapper> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Color? backgroundColor;
    if (widget.isSelected) {
      backgroundColor = Theme.of(context)
          .colorScheme
          .primaryContainer
          .withValues(alpha: 0.25);
    } else if (_isHovered) {
      backgroundColor = Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.4);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: backgroundColor,
          child: widget.child,
        ),
      ),
    );
  }
}

class MapWidget extends StatelessWidget {
  final MapController mapController;
  final TileLayer tileLayer;
  final List<Polyline> polylines;
  final List<Polygon>? polygons;
  final List<Marker> markers;
  final bool isEditing;
  final bool isRightClickSelecting;
  final bool isDraggingHoverDot;
  final bool isDraggingPlace;
  final Function(PointerHoverEvent, LatLng) onHover;
  final Function(PointerDownEvent, LatLng) onPointerDown;
  final Function(PointerMoveEvent, LatLng) onPointerMove;
  final Function(PointerUpEvent, LatLng) onPointerUp;
  final ProjectionResult? hoveredProjection;
  final List<LocationPoint> pointsToShow;
  final double timezoneOffset;
  final String Function(DateTime, double) formatPointTime;

  const MapWidget({
    super.key,
    required this.mapController,
    required this.tileLayer,
    required this.polylines,
    this.polygons,
    required this.markers,
    required this.isEditing,
    this.isRightClickSelecting = false,
    this.isDraggingHoverDot = false,
    this.isDraggingPlace = false,
    required this.onHover,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.hoveredProjection,
    required this.pointsToShow,
    required this.timezoneOffset,
    required this.formatPointTime,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        final RenderBox renderBox = context.findRenderObject() as RenderBox;
        final localOffset = renderBox.globalToLocal(event.position);
        try {
          final latLng = mapController.camera.screenOffsetToLatLng(localOffset);
          onPointerDown(event, latLng);
        } catch (_) {}
      },
      onPointerMove: (event) {
        final RenderBox renderBox = context.findRenderObject() as RenderBox;
        final localOffset = renderBox.globalToLocal(event.position);
        try {
          final latLng = mapController.camera.screenOffsetToLatLng(localOffset);
          onPointerMove(event, latLng);
        } catch (_) {}
      },
      onPointerUp: (event) {
        final RenderBox renderBox = context.findRenderObject() as RenderBox;
        final localOffset = renderBox.globalToLocal(event.position);
        try {
          final latLng = mapController.camera.screenOffsetToLatLng(localOffset);
          onPointerUp(event, latLng);
        } catch (_) {}
      },
      child: MouseRegion(
        onHover: (event) {
          final RenderBox renderBox = context.findRenderObject() as RenderBox;
          final localOffset = renderBox.globalToLocal(event.position);
          try {
            final latLng =
                mapController.camera.screenOffsetToLatLng(localOffset);
            onHover(event, latLng);
          } catch (_) {}
        },
        child: Stack(
          children: [
            FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: const LatLng(10.7790301, 106.6837685),
                initialZoom: 13.0,
                interactionOptions: InteractionOptions(
                  flags: (isEditing ||
                          isRightClickSelecting ||
                          isDraggingHoverDot ||
                          isDraggingPlace)
                      ? InteractiveFlag.all & ~InteractiveFlag.drag
                      : InteractiveFlag.all,
                ),
              ),
              children: [
                tileLayer,
                if (polygons != null && polygons!.isNotEmpty)
                  PolygonLayer(polygons: polygons!),
                PolylineLayer(polylines: polylines),
                MarkerLayer(markers: markers),
              ],
            ),
            if (isEditing &&
                hoveredProjection != null &&
                pointsToShow.length >= 2)
              Positioned(
                top: 16,
                right: 16,
                child: Card(
                  color: Colors.black87,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12.0, vertical: 8.0),
                    child: Text(
                      'Interpolated time: ${formatPointTime(
                        _getInterpolatedTime(hoveredProjection!, pointsToShow),
                        timezoneOffset,
                      )}\nClick to insert coordinate point',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  DateTime _getInterpolatedTime(
      ProjectionResult proj, List<LocationPoint> points) {
    final index = proj.insertIndex;
    if (index < 1 || index > points.length) return DateTime.now();
    final tPrev = points[index - 1].timestamp;
    final tNext = points[index].timestamp;
    final totalDuration = tNext.difference(tPrev);
    final offsetMs = (totalDuration.inMilliseconds * proj.t).toInt();
    return tPrev.add(Duration(milliseconds: offsetMs));
  }
}

class CustomCalendarDialog extends StatefulWidget {
  final DateTime initialDate;
  final List<DateInfo> allDates;
  final List<PhotoEntry>? photos;

  const CustomCalendarDialog({
    super.key,
    required this.initialDate,
    required this.allDates,
    this.photos,
  });

  @override
  State<CustomCalendarDialog> createState() => _CustomCalendarDialogState();
}

class _CustomCalendarDialogState extends State<CustomCalendarDialog> {
  late int _displayYear;
  late int _displayMonth;

  @override
  void initState() {
    super.initState();
    _displayYear = widget.initialDate.year;
    _displayMonth = widget.initialDate.month;
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_displayYear, _displayMonth + 1, 0).day;
    final firstDayOfWeek = DateTime(_displayYear, _displayMonth, 1)
        .weekday; // 1 = Monday, 7 = Sunday
    final paddingCount = firstDayOfWeek - 1;

    final monthName =
        DateFormat('MMMM yyyy').format(DateTime(_displayYear, _displayMonth));

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    setState(() {
                      if (_displayMonth == 1) {
                        _displayMonth = 12;
                        _displayYear--;
                      } else {
                        _displayMonth--;
                      }
                    });
                  },
                ),
                Text(
                  monthName,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () {
                    setState(() {
                      if (_displayMonth == 12) {
                        _displayMonth = 1;
                        _displayYear++;
                      } else {
                        _displayMonth++;
                      }
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _DayHeaderCell('M'),
                _DayHeaderCell('T'),
                _DayHeaderCell('W'),
                _DayHeaderCell('T'),
                _DayHeaderCell('F'),
                _DayHeaderCell('S'),
                _DayHeaderCell('S'),
              ],
            ),
            const Divider(),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: paddingCount + daysInMonth,
              itemBuilder: (context, index) {
                if (index < paddingCount) {
                  return const SizedBox.shrink();
                }

                final day = index - paddingCount + 1;
                final date = DateTime(_displayYear, _displayMonth, day);

                DateInfo? dayInfo;
                for (final d in widget.allDates) {
                  if (d.date.year == date.year &&
                      d.date.month == date.month &&
                      d.date.day == date.day) {
                    dayInfo = d;
                    break;
                  }
                }

                Color cellColor = Colors.transparent;
                Color textColor = Theme.of(context).colorScheme.onSurface;

                if (dayInfo != null) {
                  if (dayInfo.state == 'snapped') {
                    cellColor = Colors.green.shade100;
                    textColor = Colors.green.shade900;
                  } else if (dayInfo.state == 'edited') {
                    cellColor = Colors.blue.shade100;
                    textColor = Colors.blue.shade900;
                  } else {
                    // Unedited date -> White instead of grey
                    cellColor = Colors.white;
                    textColor = Colors.grey.shade900;
                  }
                }

                Color? dotColor;
                if (widget.photos != null && widget.photos!.isNotEmpty) {
                  final photosOnDate = widget.photos!
                      .where((p) =>
                          p.dateTaken != null &&
                          p.dateTaken!.year == date.year &&
                          p.dateTaken!.month == date.month &&
                          p.dateTaken!.day == date.day)
                      .toList();

                  if (photosOnDate.isNotEmpty) {
                    final allGeotagged =
                        photosOnDate.every((p) => p.gpsLatLng != null);
                    dotColor = allGeotagged ? Colors.purple : Colors.blue;
                  }
                }

                final isSelected = widget.initialDate.year == date.year &&
                    widget.initialDate.month == date.month &&
                    widget.initialDate.day == date.day;

                return InkWell(
                  onTap: () {
                    Navigator.pop(context, date);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cellColor,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          day.toString(),
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.0,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: textColor,
                          ),
                        ),
                        SizedBox(height: dotColor != null ? 3 : 0),
                        if (dotColor != null)
                          Container(
                            width: 4.5,
                            height: 4.5,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : dotColor,
                              shape: BoxShape.circle,
                            ),
                          )
                        else
                          const SizedBox(height: 4.5),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DayHeaderCell extends StatelessWidget {
  final String text;
  const _DayHeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
              fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey),
        ),
      ),
    );
  }
}

class MonthlyDistanceChart extends StatefulWidget {
  final DateTime selectedDate;
  final List<DateInfo> allDates;
  final List<LocationPoint> points;
  final double timezoneOffset;
  final Function(DateTime) onDateSelected;

  const MonthlyDistanceChart({
    super.key,
    required this.selectedDate,
    required this.allDates,
    required this.points,
    required this.timezoneOffset,
    required this.onDateSelected,
  });

  @override
  State<MonthlyDistanceChart> createState() => _MonthlyDistanceChartState();
}

class _MonthlyDistanceChartState extends State<MonthlyDistanceChart> {
  String _mode = 'daily'; // 'daily', 'monthly', 'yearly'
  int? _hoveredIndex;

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. Calculate totals

    final totalYearDistance = widget.allDates
        .where((d) => d.date.year == widget.selectedDate.year)
        .fold(0.0, (sum, d) => sum + d.distance);

    // 2. Prepare Mode Data
    int itemCount = 0;
    List<double> distances = [];
    List<String> labels = [];
    double maxDist = 1.0;

    // Monthly/Daily mode local vars
    final daysInMonth =
        DateTime(widget.selectedDate.year, widget.selectedDate.month + 1, 0)
            .day;
    final Map<int, DateInfo> monthData = {};

    if (_mode == 'daily') {
      // Show days 1..31 of the selected month
      itemCount = daysInMonth;
      for (final d in widget.allDates) {
        if (d.date.year == widget.selectedDate.year &&
            d.date.month == widget.selectedDate.month) {
          monthData[d.date.day] = d;
          if (d.distance > maxDist) {
            maxDist = d.distance;
          }
        }
      }
      distances =
          List.generate(daysInMonth, (i) => monthData[i + 1]?.distance ?? 0.0);
      labels = List.generate(daysInMonth, (i) => (i + 1).toString());
    } else if (_mode == 'monthly') {
      // Show months Jan..Dec of the selected year
      itemCount = 12;
      final monthlyDistances = List.filled(12, 0.0);
      for (int m = 1; m <= 12; m++) {
        monthlyDistances[m - 1] = widget.allDates
            .where((d) =>
                d.date.year == widget.selectedDate.year && d.date.month == m)
            .fold(0.0, (sum, d) => sum + d.distance);
      }
      distances = monthlyDistances;
      maxDist =
          distances.fold(1.0, (maxVal, val) => val > maxVal ? val : maxVal);
      labels = List.generate(
          12, (index) => DateFormat('MMM').format(DateTime(2020, index + 1)));
    } else {
      // Show 7 years centered around the selected year
      final currentYear = widget.selectedDate.year;
      final List<int> years = List.generate(7, (i) => currentYear - 3 + i);
      itemCount = 7;
      distances = years
          .map((y) => widget.allDates
              .where((d) => d.date.year == y)
              .fold(0.0, (sum, d) => sum + d.distance))
          .toList();
      labels = years.map((y) => y.toString()).toList();
      maxDist =
          distances.fold(1.0, (maxVal, val) => val > maxVal ? val : maxVal);
    }

    final selectedDateInfo = widget.allDates.firstWhere(
      (d) =>
          d.date.year == widget.selectedDate.year &&
          d.date.month == widget.selectedDate.month &&
          d.date.day == widget.selectedDate.day,
      orElse: () => DateInfo(
        date: widget.selectedDate,
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    // Header title and active hover description
    String titleText = 'Day Distance';
    String currentModeTotal = _formatDistance(selectedDateInfo.distance);
    if (_mode == 'monthly') {
      titleText = 'Month Distance';
      currentModeTotal = _formatDistance(totalYearDistance);
    } else if (_mode == 'yearly') {
      titleText = 'Year Distance';
      currentModeTotal = _formatDistance(totalYearDistance);
    }

    Widget? hoverSubtitle;
    if (_hoveredIndex != null && _hoveredIndex! < itemCount) {
      if (_mode == 'daily') {
        final day = _hoveredIndex! + 1;
        hoverSubtitle = Text(
          'Day $day: ${_formatDistance(distances[_hoveredIndex!])}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
      } else if (_mode == 'monthly') {
        final monthName = DateFormat('MMMM')
            .format(DateTime(widget.selectedDate.year, _hoveredIndex! + 1));
        hoverSubtitle = Text(
          '$monthName: ${_formatDistance(distances[_hoveredIndex!])}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
      } else {
        final yearVal = widget.selectedDate.year - 3 + _hoveredIndex!;
        hoverSubtitle = Text(
          'Year $yearVal: ${_formatDistance(distances[_hoveredIndex!])}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$titleText ($currentModeTotal)',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (hoverSubtitle != null) ...[
                        const SizedBox(height: 2),
                        hoverSubtitle,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        if (_mode == 'daily') {
                          widget.onDateSelected(widget.selectedDate
                              .subtract(const Duration(days: 1)));
                        } else if (_mode == 'monthly') {
                          final newMonth = widget.selectedDate.month == 1
                              ? 12
                              : widget.selectedDate.month - 1;
                          final newYear = widget.selectedDate.month == 1
                              ? widget.selectedDate.year - 1
                              : widget.selectedDate.year;
                          final daysInNewMonth =
                              DateTime(newYear, newMonth + 1, 0).day;
                          final targetDay =
                              widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(
                              DateTime(newYear, newMonth, targetDay));
                        } else {
                          final newYear = widget.selectedDate.year - 1;
                          final daysInNewMonth = DateTime(
                                  newYear, widget.selectedDate.month + 1, 0)
                              .day;
                          final targetDay =
                              widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(
                              newYear, widget.selectedDate.month, targetDay));
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        if (_mode == 'daily') {
                          widget.onDateSelected(
                              widget.selectedDate.add(const Duration(days: 1)));
                        } else if (_mode == 'monthly') {
                          final newMonth = widget.selectedDate.month == 12
                              ? 1
                              : widget.selectedDate.month + 1;
                          final newYear = widget.selectedDate.month == 12
                              ? widget.selectedDate.year + 1
                              : widget.selectedDate.year;
                          final daysInNewMonth =
                              DateTime(newYear, newMonth + 1, 0).day;
                          final targetDay =
                              widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(
                              DateTime(newYear, newMonth, targetDay));
                        } else {
                          final newYear = widget.selectedDate.year + 1;
                          final daysInNewMonth = DateTime(
                                  newYear, widget.selectedDate.month + 1, 0)
                              .day;
                          final targetDay =
                              widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(
                              newYear, widget.selectedDate.month, targetDay));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _mode,
                    isDense: true,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Day')),
                      DropdownMenuItem(value: 'monthly', child: Text('Month')),
                      DropdownMenuItem(value: 'yearly', child: Text('Year')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _mode = val;
                          _hoveredIndex = null;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  final double val = distances[index];
                  final String label = labels[index];

                  double heightFactor = (val / maxDist).clamp(0.05, 1.0);
                  Color barColor = Colors.grey.shade300;

                  bool isActive = false;
                  if (_mode == 'daily') {
                    final day = index + 1;
                    isActive = day == widget.selectedDate.day;
                    final dayInfo = monthData[day];
                    if (dayInfo != null) {
                      if (dayInfo.state == 'snapped') {
                        barColor = Colors.green.shade300;
                      } else if (dayInfo.state == 'edited') {
                        barColor = Colors.blue.shade300;
                      } else {
                        barColor = Colors.grey.shade400;
                      }
                    }
                  } else if (_mode == 'monthly') {
                    isActive = (index + 1) == widget.selectedDate.month;
                  } else {
                    final currentYear = widget.selectedDate.year;
                    final List<int> years =
                        List.generate(7, (i) => currentYear - 3 + i);
                    isActive = years[index] == widget.selectedDate.year;
                  }

                  if (isActive) {
                    barColor = Theme.of(context).colorScheme.primary;
                  }

                  if (_hoveredIndex == index) {
                    barColor = Theme.of(context).colorScheme.secondary;
                  }

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _hoveredIndex = index;
                      });
                      if (_mode == 'daily') {
                        final clickedDate = DateTime(
                          widget.selectedDate.year,
                          widget.selectedDate.month,
                          index + 1,
                        );
                        widget.onDateSelected(clickedDate);
                      } else if (_mode == 'monthly') {
                        final clickedDate = DateTime(
                          widget.selectedDate.year,
                          index + 1,
                          1,
                        );
                        widget.onDateSelected(clickedDate);
                      } else {
                        final currentYear = widget.selectedDate.year;
                        final List<int> years =
                            List.generate(7, (i) => currentYear - 3 + i);
                        final clickedDate = DateTime(
                          years[index],
                          widget.selectedDate.month,
                          widget.selectedDate.day,
                        );
                        widget.onDateSelected(clickedDate);
                      }
                    },
                    child: Container(
                      width: _mode == 'daily'
                          ? 24
                          : (_mode == 'monthly' ? 35 : 45),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: FractionallySizedBox(
                              heightFactor: heightFactor,
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: barColor,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CachedTileProvider extends TileProvider {
  CachedTileProvider();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return CachedNetworkImageProvider(getTileUrl(coordinates, options));
  }
}

class BingTileProvider extends CachedTileProvider {
  BingTileProvider();

  @override
  String getTileUrl(TileCoordinates coordinates, TileLayer options) {
    final x = coordinates.x;
    final y = coordinates.y;
    final z = coordinates.z;
    final quadKey = _getQuadKey(x, y, z);
    return options.urlTemplate!.replaceAll('{quadkey}', quadKey);
  }

  String _getQuadKey(int x, int y, int z) {
    var quadKey = StringBuffer();
    for (var i = z; i > 0; i--) {
      var digit = 0;
      var mask = 1 << (i - 1);
      if ((x & mask) != 0) digit++;
      if ((y & mask) != 0) digit += 2;
      quadKey.write(digit.toString());
    }
    return quadKey.toString();
  }
}

abstract class TimelineItem {
  DateTime get startTime;
  DateTime get endTime;
}

class TimelinePlace extends TimelineItem {
  final List<LocationPoint> points;
  @override
  final DateTime startTime;
  @override
  final DateTime endTime;
  final LatLng center;
  List<PhotoEntry> geotaggedPhotos = [];
  List<PhotoEntry> ungeotaggedPhotos = [];

  TimelinePlace({
    required this.points,
    required this.startTime,
    required this.endTime,
    required this.center,
  });

  Duration get duration => endTime.difference(startTime);
}

class TimelinePath extends TimelineItem {
  final List<LocationPoint> points;
  @override
  final DateTime startTime;
  @override
  final DateTime endTime;
  final double distance;
  List<PhotoEntry> geotaggedPhotos = [];
  List<PhotoEntry> ungeotaggedPhotos = [];

  TimelinePath({
    required this.points,
    required this.startTime,
    required this.endTime,
    required this.distance,
  });

  Duration get duration => endTime.difference(startTime);
}

class CustomCalendarInline extends StatefulWidget {
  final DateTime selectedDate;
  final List<DateInfo> allDates;
  final List<PhotoEntry>? photos;
  final Function(DateTime) onDateSelected;
  final VoidCallback onClose;

  const CustomCalendarInline({
    super.key,
    required this.selectedDate,
    required this.allDates,
    this.photos,
    required this.onDateSelected,
    required this.onClose,
  });

  @override
  State<CustomCalendarInline> createState() => _CustomCalendarInlineState();
}

class _CustomCalendarInlineState extends State<CustomCalendarInline> {
  late int _displayYear;
  late int _displayMonth;

  @override
  void initState() {
    super.initState();
    _displayYear = widget.selectedDate.year;
    _displayMonth = widget.selectedDate.month;
  }

  @override
  void didUpdateWidget(covariant CustomCalendarInline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedDate != widget.selectedDate) {
      _displayYear = widget.selectedDate.year;
      _displayMonth = widget.selectedDate.month;
    }
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_displayYear, _displayMonth + 1, 0).day;
    final firstDayOfWeek = DateTime(_displayYear, _displayMonth, 1)
        .weekday; // 1 = Monday, 7 = Sunday
    final paddingCount = firstDayOfWeek - 1;

    final monthName =
        DateFormat('MMMM yyyy').format(DateTime(_displayYear, _displayMonth));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.3),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    if (_displayMonth == 1) {
                      _displayMonth = 12;
                      _displayYear--;
                    } else {
                      _displayMonth--;
                    }
                  });
                },
              ),
              Text(
                monthName,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_right, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      setState(() {
                        if (_displayMonth == 12) {
                          _displayMonth = 1;
                          _displayYear++;
                        } else {
                          _displayMonth++;
                        }
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: widget.onClose,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Hide', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _DayHeaderCell('M'),
              _DayHeaderCell('T'),
              _DayHeaderCell('W'),
              _DayHeaderCell('T'),
              _DayHeaderCell('F'),
              _DayHeaderCell('S'),
              _DayHeaderCell('S'),
            ],
          ),
          const Divider(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: paddingCount + daysInMonth,
            itemBuilder: (context, index) {
              if (index < paddingCount) {
                return const SizedBox.shrink();
              }

              final day = index - paddingCount + 1;
              final date = DateTime(_displayYear, _displayMonth, day);

              DateInfo? dayInfo;
              for (final d in widget.allDates) {
                if (d.date.year == date.year &&
                    d.date.month == date.month &&
                    d.date.day == date.day) {
                  dayInfo = d;
                  break;
                }
              }

              Color cellColor = Colors.transparent;
              Color textColor = Theme.of(context).colorScheme.onSurface;

              if (dayInfo != null) {
                if (dayInfo.state == 'snapped') {
                  cellColor = Colors.green.shade100;
                  textColor = Colors.green.shade900;
                } else if (dayInfo.state == 'edited') {
                  cellColor = Colors.blue.shade100;
                  textColor = Colors.blue.shade900;
                } else {
                  // Unedited date -> White instead of grey
                  cellColor = Colors.white;
                  textColor = Colors.grey.shade900;
                }
              }

              Color? dotColor;
              if (widget.photos != null && widget.photos!.isNotEmpty) {
                final photosOnDate = widget.photos!
                    .where((p) =>
                        p.dateTaken != null &&
                        p.dateTaken!.year == date.year &&
                        p.dateTaken!.month == date.month &&
                        p.dateTaken!.day == date.day)
                    .toList();

                if (photosOnDate.isNotEmpty) {
                  final allGeotagged =
                      photosOnDate.every((p) => p.gpsLatLng != null);
                  dotColor = allGeotagged ? Colors.purple : Colors.blue;
                }
              }

              final isSelected = widget.selectedDate.year == date.year &&
                  widget.selectedDate.month == date.month &&
                  widget.selectedDate.day == date.day;

              return InkWell(
                onTap: () {
                  widget.onDateSelected(date);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : cellColor,
                    borderRadius: BorderRadius.circular(8),
                    border: isSelected
                        ? null
                        : (date.year == DateTime.now().year &&
                                date.month == DateTime.now().month &&
                                date.day == DateTime.now().day)
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 1)
                            : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        day.toString(),
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.0,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? Theme.of(context).colorScheme.onPrimary
                              : textColor,
                        ),
                      ),
                      SizedBox(height: dotColor != null ? 3 : 0),
                      if (dotColor != null)
                        Container(
                          width: 4.5,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white : dotColor,
                            shape: BoxShape.circle,
                          ),
                        )
                      else
                        const SizedBox(height: 4.5),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
