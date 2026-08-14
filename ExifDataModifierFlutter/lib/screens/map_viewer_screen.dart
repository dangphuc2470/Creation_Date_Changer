// ignore_for_file: unused_field

import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
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
import '../models/favorite_road.dart';
import '../models/lens_template.dart';
import '../providers/app_state_provider.dart';
import '../providers/settings_provider.dart';
import '../services/location_manager.dart';
import '../constants/timeline_constants.dart';
import '../utils/geo_utils.dart';
import '../services/nominatim_service.dart';
import '../services/thumbnail_service.dart';

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

bool _isInvalidLensName(String? val) {
  if (val == null) return true;
  final lower = val.trim().toLowerCase();
  if (lower.isEmpty ||
      lower == '0' ||
      lower == '0mm' ||
      lower == '0.0mm' ||
      lower == '0.0 mm' ||
      lower == '-' ||
      lower == 'n/a' ||
      lower == 'none' ||
      lower.startsWith('unknown') ||
      lower.contains('unknown (') ||
      // Canon manual/chipless lens sentinel: full focal range 1-65535mm
      lower == '1-65535mm' ||
      lower.startsWith('1-65535')) {
    return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo entry: dropped/picked photo with optional EXIF GPS
// ─────────────────────────────────────────────────────────────────────────────
class PhotoEntry {
  final File file;
  final String filename;
  File? thumbnailFile;

  /// Stored as DateTime.utc() but with LOCAL time values from EXIF.
  /// Subtract timezone offset to get proper UTC for comparisons.
  DateTime? dateTaken;

  /// GPS from EXIF (or user-dragged). Null when photo has no GPS.
  LatLng? gpsLatLng;

  /// Position inferred by interpolating timeline at dateTaken.
  /// Only populated for photos without EXIF GPS.
  LatLng? interpolatedLatLng;
  bool addedToTimeline = false;
  bool isGpsModified = false;

  /// Lens & Camera metadata
  String? lensModel;
  String? lensMake;
  double? focalLength;
  double? fNumber;
  String? shutterSpeed;

  PhotoEntry({required this.file, required this.filename}) {
    try {
      final match = RegExp(
              r'(20\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})')
          .firstMatch(filename);
      if (match != null) {
        dateTaken = DateTime.utc(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
          int.parse(match.group(4)!),
          int.parse(match.group(5)!),
          int.parse(match.group(6)!),
        );
      }
    } catch (_) {}
  }

  /// Position shown on map: EXIF GPS (may be dragged) or interpolated.
  LatLng? get assignedLatLng => gpsLatLng ?? interpolatedLatLng;
  bool get hasExifGps => gpsLatLng != null;
  bool get hasLensInfo => !_isInvalidLensName(lensModel);

  Map<String, dynamic> toJson() {
    return {
      'filePath': file.path,
      'filename': filename,
      'dateTaken': dateTaken?.toIso8601String(),
      'gpsLat': gpsLatLng?.latitude,
      'gpsLng': gpsLatLng?.longitude,
      'interpolatedLat': interpolatedLatLng?.latitude,
      'interpolatedLng': interpolatedLatLng?.longitude,
      'addedToTimeline': addedToTimeline,
      'isGpsModified': isGpsModified,
      'lensModel': _isInvalidLensName(lensModel) ? null : lensModel,
      'lensMake': lensMake,
      'focalLength': focalLength,
      'fNumber': fNumber,
      'shutterSpeed': shutterSpeed,
    };
  }

  factory PhotoEntry.fromJson(Map<String, dynamic> json) {
    final entry = PhotoEntry(
      file: File(json['filePath'] as String),
      filename: json['filename'] as String? ?? '',
    );
    if (json['dateTaken'] != null) {
      entry.dateTaken = DateTime.tryParse(json['dateTaken'] as String);
    }
    if (json['gpsLat'] != null && json['gpsLng'] != null) {
      entry.gpsLatLng = LatLng(
        (json['gpsLat'] as num).toDouble(),
        (json['gpsLng'] as num).toDouble(),
      );
    }
    if (json['interpolatedLat'] != null && json['interpolatedLng'] != null) {
      entry.interpolatedLatLng = LatLng(
        (json['interpolatedLat'] as num).toDouble(),
        (json['interpolatedLng'] as num).toDouble(),
      );
    }
    entry.addedToTimeline = json['addedToTimeline'] as bool? ?? false;
    entry.isGpsModified = json['isGpsModified'] as bool? ?? false;
    final rawLens = json['lensModel'] as String?;
    entry.lensModel = _isInvalidLensName(rawLens) ? null : rawLens;
    entry.lensMake = json['lensMake'] as String?;
    if (json['focalLength'] != null) {
      entry.focalLength = (json['focalLength'] as num).toDouble();
    }
    if (json['fNumber'] != null) {
      entry.fNumber = (json['fNumber'] as num).toDouble();
    }
    entry.shutterSpeed = json['shutterSpeed'] as String?;
    return entry;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom Fade Context Menu (Fade-only transition without expand/scale animation)
// ─────────────────────────────────────────────────────────────────────────────
Future<T?> showFadeMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  double? elevation,
  ShapeBorder? shape,
  Color? color,
  bool useRootNavigator = false,
}) {
  assert(items.isNotEmpty);

  final NavigatorState navigator =
      Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push(
    _FadePopupMenuRoute<T>(
      position: position,
      items: items,
      elevation: elevation,
      shape: shape,
      color: color,
    ),
  );
}

class _FadePopupMenuRoute<T> extends PopupRoute<T> {
  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final ShapeBorder? shape;
  final Color? color;
  final double? elevation;

  _FadePopupMenuRoute({
    required this.position,
    required this.items,
    this.shape,
    this.color,
    this.elevation,
  });

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: CustomSingleChildLayout(
        delegate: _PopupMenuLayoutDelegate(
          position: position,
          padding: mediaQuery.padding,
        ),
        child: Material(
          type: MaterialType.card,
          elevation: elevation ?? 8.0,
          color: color ?? Theme.of(context).colorScheme.surface,
          shape: shape ??
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: items,
            ),
          ),
        ),
      ),
    );
  }
}

class _PopupMenuLayoutDelegate extends SingleChildLayoutDelegate {
  final RelativeRect position;
  final EdgeInsets padding;

  _PopupMenuLayoutDelegate({
    required this.position,
    required this.padding,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = position.left;
    double y = position.top;
    if (x + childSize.width > size.width) {
      x = size.width - childSize.width - 8;
    }
    if (y + childSize.height > size.height) {
      y = size.height - childSize.height - 8;
    }
    return Offset(max(0.0, x), max(0.0, y));
  }

  @override
  bool shouldRelayout(_PopupMenuLayoutDelegate oldDelegate) {
    return position != oldDelegate.position;
  }
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
  final bool _viewAsPath = true;
  double _sidebarWidth = 380.0;
  String _chartMode = 'daily';

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
  bool _ignoreNextPlaceContextMenu = false;
  final Map<String, List<LocationPoint>> _unsnappedSegmentBackups = {};
  bool _isSaving = false;
  int _savingCount = 0; // tracks concurrent saves

  // ── Geocode cache for Place labels (lat,lng → place name) ──────────────
  final Map<String, String?> _geocodeCache = {};
  final Set<String> _geocodingInProgress = {};

  // ── Photo layer ─────────────────────────────────────────────────────────
  final List<PhotoEntry> _photos = [];
  bool _isDraggingPhotoOver = false;
  PhotoEntry? _selectedPhoto; // for strip/preview
  bool _showPhotoGrid = false;
  final ScrollController _timelineScrollController = ScrollController();

  // ── Import Progress State ────────────────────────────────────────────────
  bool _isImportingPhotos = false;
  int _importTotalPhotos = 0;
  int _importProcessedPhotos = 0;
  String _importCurrentStatus = '';

  // ── Photo drag on map ─────────────────────────────────────────────────
  PhotoEntry? _draggingPhoto;
  bool _isDraggingPhoto = false;
  LatLng? _photoDragStartLatLng;
  final Map<PhotoEntry, LatLng> _initialPhotoLocations = {};
  bool get _hasUnsavedPhotoChanges => _photos.any((p) => p.isGpsModified);

  // ── Multi-select (Ctrl+click) ─────────────────────────────────────────
  final Set<PhotoEntry> _selectedPhotoSet = {};
  PhotoEntry? _shiftStartPhoto;
  double _clusterJitterMeters = 5.0;
  int _maxClusterGroups = 3;
  bool _isWritingExif = false;
  int _exifTotal = 0;
  int _exifProcessed = 0;
  static _MapViewerScreenState? activeState;
  final List<_MacNotification> _macNotifications = [];

  void showMacToast(String message, {Color? backgroundColor}) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final notif = _MacNotification(
      id: id,
      message: message,
      backgroundColor: backgroundColor ?? Colors.green.shade700,
    );
    setState(() {
      _macNotifications.add(notif);
    });

    // Auto dismiss after 3.5 seconds
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (mounted) {
        setState(() {
          _macNotifications.removeWhere((n) => n.id == id);
        });
      }
    });
  }

  /// Focus sidebar timeline to the item that contains [photo]'s dateTaken.
  /// If no timeline item is found, falls back to the first item.
  void _focusTimelineForPhoto(PhotoEntry photo) {
    final items = _timelineItemsWithPhotos;
    if (items == null || items.isEmpty) return;
    final settings = context.read<SettingsProvider>();
    final tz = settings.geotagTimezone.toDouble();
    final taken = photo.dateTaken;

    int targetIdx = 0;
    if (taken != null) {
      final photoUtc = taken.toUtc();
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        DateTime? start;
        DateTime? end;
        if (item is TimelinePlace) {
          start = item.startTime;
          end = item.endTime;
        } else if (item is TimelinePath) {
          start = item.startTime;
          end = item.endTime;
        }
        if (start == null || end == null) continue;
        final startUtc = start.toUtc().subtract(Duration(hours: tz.toInt()));
        final endUtc = end.toUtc().subtract(Duration(hours: tz.toInt()));
        if (!photoUtc.isBefore(startUtc) && !photoUtc.isAfter(endUtc)) {
          targetIdx = i;
          break;
        }
      }
    }

    setState(() => _selectedTimelineItemIndex = targetIdx);

    // Scroll sidebar to the target item (estimate ~80px per item)
    const estimatedItemHeight = 80.0;
    final offset = (targetIdx * estimatedItemHeight)
        .clamp(0.0, _timelineScrollController.position.maxScrollExtent);
    _timelineScrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  // ── Step-by-step Edit Undo Stack ─────────────────────────────────────
  final List<List<LocationPoint>> _editHistoryStack = [];

  void _pushUndoState(List<LocationPoint> points) {
    if (points.isNotEmpty) {
      _editHistoryStack.add(List<LocationPoint>.from(points));
      if (_editHistoryStack.length > 50) {
        _editHistoryStack.removeAt(0);
      }
    }
  }

  void _performUndoStep(
      AppStateProvider appState, DateInfo dateInfo, double tz) {
    if (_editHistoryStack.isEmpty) return;
    final prevPoints = _editHistoryStack.removeLast();

    setState(() {
      appState.activePaths[dateInfo.filePath] = prevPoints;
      _assignPhotosToTimelineItems(prevPoints, tz);
      _hoveredLatLng = null;
      _hoveredPoint = null;
    });

    _saveWithIndicator(appState, dateInfo, prevPoints);
    _loadPointsForSelectedDate(keepSelection: true);

    if (mounted) {
      _MacToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Undid 1 edit step (${_editHistoryStack.length} step${_editHistoryStack.length == 1 ? '' : 's'} remaining)',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Cached photo-assigned timeline items ──────────────────────────────
  /// Built by _assignPhotosToTimelineItems(); shared by sidebar + map.
  List<TimelineItem>? _timelineItemsWithPhotos;

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Lifecycle — initState, dispose, load/save last selected date
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    activeState = this;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _loadLastSelectedDate();
    _loadCachedPhotos();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyA) {
      // Ctrl+A: chọn hết ảnh ngày hiện tại trong strip
      setState(() {
        _selectedPhotoSet
          ..clear()
          ..addAll(_currentDatePhotos);
        if (_currentDatePhotos.isNotEmpty) {
          _selectedPhoto = _currentDatePhotos.first;
          _shiftStartPhoto = _currentDatePhotos.first;
        }
      });
      return true; // consumed
    }
    return false;
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

  // ── Photo Caching & Persistence ────────────────────────────────────────
  Future<void> _saveCachedPhotoPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _photos.map((p) => jsonEncode(p.toJson())).toList();
      await prefs.setStringList('cached_imported_photos_json', jsonList);
    } catch (e) {
      debugPrint('Error saving cached photos JSON: $e');
    }
  }

  Future<void> _loadCachedPhotos() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList('cached_imported_photos_json');

      if (jsonList != null && jsonList.isNotEmpty) {
        final restoredEntries = <PhotoEntry>[];
        for (final str in jsonList) {
          try {
            final map = jsonDecode(str) as Map<String, dynamic>;
            final entry = PhotoEntry.fromJson(map);
            if (await entry.file.exists()) {
              restoredEntries.add(entry);
            }
          } catch (_) {}
        }

        if (restoredEntries.isNotEmpty && mounted) {
          setState(() {
            _photos.addAll(restoredEntries);
          });
          await _autoInsertGeotaggedPhotoPoints(restoredEntries);
          if (!mounted) return;
          final appState = context.read<AppStateProvider>();
          final settings = context.read<SettingsProvider>();
          final dateInfo = _currentDateInfo(appState);
          final pts = appState.activePaths[dateInfo.filePath] ?? [];
          _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());

          final missingMeta = restoredEntries
              .where((e) =>
                  !e.hasLensInfo ||
                  e.shutterSpeed == null ||
                  e.shutterSpeed!.isEmpty)
              .toList();
          if (missingMeta.isNotEmpty) {
            _batchReadExifWithExifTool(missingMeta).then((_) {
              _saveCachedPhotoPaths();
              if (mounted) setState(() {});
            });
          }
          _loadThumbnailsForPhotos(restoredEntries);
        }
        return;
      }

      // Backward compatibility fallback for path-only list
      final savedPaths = prefs.getStringList('cached_imported_photo_paths');
      if (savedPaths != null && savedPaths.isNotEmpty) {
        final existingFiles = <File>[];
        for (final p in savedPaths) {
          final file = File(p);
          if (await file.exists()) {
            existingFiles.add(file);
          }
        }
        if (existingFiles.isNotEmpty) {
          await _loadPhotosFromFiles(existingFiles, isRestoringCache: true);
        }
      }
    } catch (e) {
      debugPrint('Error loading cached photos: $e');
    }
  }

  void _loadThumbnailsForPhotos(List<PhotoEntry> entries) {
    if (entries.isEmpty) return;

    for (final entry in entries) {
      if (entry.thumbnailFile != null) continue;
      ThumbnailService.getCachedThumbnail(entry.file.path).then((thumbFile) {
        if (thumbFile != null && mounted) {
          setState(() {
            entry.thumbnailFile = thumbFile;
          });
        }
      });
    }

    final missingPaths = entries
        .where((e) => e.thumbnailFile == null)
        .map((e) => e.file.path)
        .toList();

    if (missingPaths.isEmpty) return;

    final entryMap = <String, PhotoEntry>{
      for (final e in entries) e.file.path: e,
    };

    ThumbnailService.batchEnsureThumbnails(
      missingPaths,
      onItemDone: (filePath, thumbFile) {
        final entry = entryMap[filePath];
        if (entry != null && mounted) {
          setState(() {
            entry.thumbnailFile = thumbFile;
          });
        }
      },
    );
  }



  Future<void> _clearCachedPhotos() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cached_imported_photo_paths');
      await prefs.remove('cached_imported_photos_json');
      setState(() {
        _photos.clear();
        _selectedPhoto = null;
        _selectedPhotoSet.clear();
        _shiftStartPhoto = null;
        _timelineItemsWithPhotos = null;
      });
      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cleared all cached imported photos.')),
        );
      }
    } catch (e) {
      debugPrint('Error clearing cached photos: $e');
    }
  }

  void _loadPointsForSelectedDate(
      {bool fitBounds = true, bool keepSelection = false}) async {
    setState(() {
      if (!keepSelection) {
        _selectedTimelineItemIndex = null;
      }
      _selectedPhoto = null;
      _selectedPhotoSet.clear();
      _shiftStartPhoto = null;
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
    if (activeState == this) {
      activeState = null;
    }
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _mapAnimationController?.dispose();
    _timelineScrollController.dispose();
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
      return Uint8List(0);
    }
  }

  Future<void> _readExifFromPhoto(PhotoEntry entry) async {
    try {
      Map<String, IfdTag> tags = {};
      try {
        final headerBytes =
            await _readFileHeaderBytes(entry.file, maxHeaderBytes: 524288);
        tags = await readExifFromBytes(headerBytes);
      } catch (_) {
        try {
          final headerBytes2 =
              await _readFileHeaderBytes(entry.file, maxHeaderBytes: 1048576);
          tags = await readExifFromBytes(headerBytes2);
        } catch (_) {}
      }

      if (tags.isNotEmpty) {
        // Date: Check all standard EXIF date/time tags from photo metadata
        final dateTag = tags['EXIF DateTimeOriginal'] ??
            tags['Image DateTime'] ??
            tags['EXIF DateTimeDigitized'] ??
            tags['Image DateTimeOriginal'] ??
            tags['EXIF CreateDate'] ??
            tags['EXIF ModifyDate'];

        if (dateTag != null) {
          final raw = dateTag.printable.trim(); // e.g. "2026:05:24 19:05:45"
          final cleanRaw = raw.replaceAll(':', '-');
          final parts = cleanRaw.split(' ');
          if (parts.length >= 2) {
            final dateParts = parts[0].split('-');
            final timeParts = parts[1].split('-');
            if (dateParts.length == 3 && timeParts.length >= 3) {
              try {
                entry.dateTaken = DateTime.utc(
                  int.parse(dateParts[0]),
                  int.parse(dateParts[1]),
                  int.parse(dateParts[2]),
                  int.parse(timeParts[0]),
                  int.parse(timeParts[1]),
                  int.parse(timeParts[2].split('.')[0]),
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

        // Lens Model (e.g. MakerNote LensModel: EF50mm f/1.8 STM)
        final lensTag = tags['MakerNote LensModel'] ??
            tags['EXIF LensModel'] ??
            tags['EXIF LensID'] ??
            tags['Image LensModel'];
        if (lensTag != null) {
          final val = lensTag.printable.trim();
          if (val.isNotEmpty && val != '-') {
            entry.lensModel = val;
          }
        }

        // Focal Length
        final focalTag = tags['EXIF FocalLength'];
        if (focalTag != null) {
          try {
            if (focalTag.values is IfdRatios) {
              final r = (focalTag.values as IfdRatios).ratios.first;
              entry.focalLength =
                  r.numerator / (r.denominator == 0 ? 1 : r.denominator);
            }
          } catch (_) {}
        }

        // FNumber
        final fNumTag = tags['EXIF FNumber'];
        if (fNumTag != null) {
          try {
            if (fNumTag.values is IfdRatios) {
              final r = (fNumTag.values as IfdRatios).ratios.first;
              entry.fNumber =
                  r.numerator / (r.denominator == 0 ? 1 : r.denominator);
            }
          } catch (_) {}
        }

        // Exposure Time (Shutter speed)
        final shutterTag = tags['EXIF ExposureTime'] ??
            tags['EXIF ShutterSpeedValue'] ??
            tags['Image ExposureTime'];
        if (shutterTag != null) {
          final rawVal = shutterTag.printable.trim();
          if (rawVal.isNotEmpty && rawVal != '-') {
            entry.shutterSpeed = rawVal.endsWith('s') ? rawVal : '${rawVal}s';
          }
        }
      }
    } catch (e) {
      debugPrint('EXIF read error for ${entry.filename}: $e');
    }

    // Fallback: extract date from filename pattern (e.g. 6D_20260524_190545_01047.JPG or 5D2_20260524_172117.JPG)
    if (entry.dateTaken == null) {
      try {
        final match = RegExp(
                r'(20\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})')
            .firstMatch(entry.filename);
        if (match != null) {
          entry.dateTaken = DateTime.utc(
            int.parse(match.group(1)!),
            int.parse(match.group(2)!),
            int.parse(match.group(3)!),
            int.parse(match.group(4)!),
            int.parse(match.group(5)!),
            int.parse(match.group(6)!),
          );
        }
      } catch (_) {}
    }
  }

  List<String> _parseCsvLine(String line) {
    List<String> result = [];
    bool insideQuotes = false;
    StringBuffer sb = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        insideQuotes = !insideQuotes;
      } else if (char == ',' && !insideQuotes) {
        result.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(char);
      }
    }
    result.add(sb.toString().trim());
    return result;
  }

  /// Fast batch EXIF scanner using ExifTool CSV with -fast2 flag & -@ argfile (ultra-fast 10x batch header reading)
  Future<void> _batchReadExifWithExifTool(List<PhotoEntry> entries) async {
    if (entries.isEmpty) return;
    try {
      final exe = await _getExifToolExecutable();
      final tempDir = await getTemporaryDirectory();
      const int maxChunkSize = 1000;

      for (int i = 0; i < entries.length; i += maxChunkSize) {
        final chunk = entries.sublist(
          i,
          i + maxChunkSize > entries.length ? entries.length : i + maxChunkSize,
        );

        final timestamp = DateTime.now().microsecondsSinceEpoch;
        final argFile = File(path.join(tempDir.path, 'read_exif_$timestamp.txt'));
        await argFile.writeAsString(chunk.map((e) => e.file.path).join('\n'), flush: true);

        final args = [
          '-c',
          '%.6f',
          '-GPSLatitude#',
          '-GPSLongitude#',
          '-DateTimeOriginal',
          '-LensModel',
          '-LensID',
          '-Lens',
          '-LensMake',
          '-FocalLength#',
          '-FNumber#',
          '-ExposureTime',
          '-d',
          '%Y-%m-%d %H:%M:%S',
          '-fast',
          '-csv',
          '-@',
          argFile.path,
        ];

        final result = await Process.run(exe, args);
        try {
          if (await argFile.exists()) await argFile.delete();
        } catch (_) {}

        final stdoutStr = result.stdout.toString().trim();

        if (result.exitCode == 0 && stdoutStr.startsWith('SourceFile')) {
          final lines = LineSplitter.split(stdoutStr).toList();
          if (lines.length > 1) {
            final header = _parseCsvLine(lines.first);
            final fileIdx = header.indexWhere((h) => h.contains('SourceFile'));
            final latIdx = header.indexWhere((h) => h.contains('GPSLatitude'));
            final lngIdx = header.indexWhere((h) => h.contains('GPSLongitude'));
            final dateIdx =
                header.indexWhere((h) => h.contains('DateTimeOriginal'));
            final lensModelIdx =
                header.indexWhere((h) => h.toLowerCase().contains('lensmodel'));
            final lensIdIdx =
                header.indexWhere((h) => h.toLowerCase().contains('lensid'));
            final lensIdx = header.indexWhere((h) => h.toLowerCase() == 'lens');
            final lensMakeIdx =
                header.indexWhere((h) => h.toLowerCase().contains('lensmake'));
            final focalIdx = header
                .indexWhere((h) => h.toLowerCase().contains('focallength'));
            final fNumIdx =
                header.indexWhere((h) => h.toLowerCase().contains('fnumber'));
            final shutterIdx = header
                .indexWhere((h) => h.toLowerCase().contains('exposuretime'));

            String normPath(String p) =>
                path.normalize(p).toLowerCase().replaceAll('/', '\\');

            final mapByPath = <String, PhotoEntry>{
              for (final e in chunk) normPath(e.file.path): e,
            };

            for (int j = 1; j < lines.length; j++) {
              final row = _parseCsvLine(lines[j]);
              if (row.isEmpty || fileIdx < 0 || fileIdx >= row.length) continue;
              final filePath = normPath(row[fileIdx]);
              final entry = mapByPath[filePath];
              if (entry == null) continue;

              // Date
              if (dateIdx >= 0 &&
                  dateIdx < row.length &&
                  row[dateIdx].isNotEmpty &&
                  row[dateIdx] != '-') {
                try {
                  final rawDate = row[dateIdx].replaceAll(':', '-');
                  final dtParts = rawDate.split(' ');
                  if (dtParts.length == 2) {
                    final dParts = dtParts[0].split('-');
                    final tParts = dtParts[1].split('-');
                    if (dParts.length == 3 && tParts.length == 3) {
                      entry.dateTaken = DateTime.utc(
                        int.parse(dParts[0]),
                        int.parse(dParts[1]),
                        int.parse(dParts[2]),
                        int.parse(tParts[0]),
                        int.parse(tParts[1]),
                        int.parse(tParts[2]),
                      );
                    }
                  }
                } catch (_) {}
              }

              // GPS
              if (latIdx >= 0 &&
                  latIdx < row.length &&
                  lngIdx >= 0 &&
                  lngIdx < row.length) {
                final lat = double.tryParse(row[latIdx]);
                final lng = double.tryParse(row[lngIdx]);
                if (lat != null && lng != null) {
                  entry.gpsLatLng = LatLng(lat, lng);
                }
              }

              // Lens info (tries LensModel -> LensID -> Lens)
              String? modelVal;
              if (lensModelIdx >= 0 &&
                  lensModelIdx < row.length &&
                  !_isInvalidLensName(row[lensModelIdx])) {
                modelVal = row[lensModelIdx];
              } else if (lensIdIdx >= 0 &&
                  lensIdIdx < row.length &&
                  !_isInvalidLensName(row[lensIdIdx])) {
                modelVal = row[lensIdIdx];
              } else if (lensIdx >= 0 &&
                  lensIdx < row.length &&
                  !_isInvalidLensName(row[lensIdx])) {
                modelVal = row[lensIdx];
              }
              if (!_isInvalidLensName(modelVal)) {
                entry.lensModel = modelVal;
              } else {
                entry.lensModel = null;
              }

              if (lensMakeIdx >= 0 &&
                  lensMakeIdx < row.length &&
                  row[lensMakeIdx].isNotEmpty &&
                  row[lensMakeIdx] != '-') {
                entry.lensMake = row[lensMakeIdx];
              }
              if (focalIdx >= 0 && focalIdx < row.length) {
                entry.focalLength = double.tryParse(row[focalIdx]);
              }
              if (fNumIdx >= 0 && fNumIdx < row.length) {
                entry.fNumber = double.tryParse(row[fNumIdx]);
              }
              if (shutterIdx >= 0 &&
                  shutterIdx < row.length &&
                  row[shutterIdx].isNotEmpty &&
                  row[shutterIdx] != '-') {
                final val = row[shutterIdx].trim();
                entry.shutterSpeed = val.endsWith('s') ? val : '${val}s';
              }
            }

            // Fallback for any items in chunk where ExifTool didn't extract date
            final unparsed = chunk.where((e) => e.dateTaken == null).toList();
            if (unparsed.isNotEmpty) {
              await Future.wait(unparsed.map(_readExifFromPhoto));
            }
          }
        } else {
          // Fallback to Dart read if ExifTool CSV fails or outputs error
          await Future.wait(chunk.map(_readExifFromPhoto));
        }

        if (mounted) {
          final processed = min(i + maxChunkSize, entries.length);
          setState(() {
            _importProcessedPhotos = processed;
            _importCurrentStatus =
                'Reading EXIF metadata ($processed / $_importTotalPhotos)...';
          });
        }
      }
    } catch (e) {
      debugPrint('ExifTool batch read error: $e');
      await Future.wait(entries.map(_readExifFromPhoto));
    }
  }

  Future<String> _getExifToolExecutable() async {
    try {
      final result = await Process.run('exiftool', ['-ver']);
      if (result.exitCode == 0) return 'exiftool';
    } catch (_) {}

    if (Platform.isWindows) {
      // 1. Try executable parent directory (where CMake deploys exiftool.exe + exiftool_files)
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final installedExe = File(path.join(exeDir.path, 'exiftool.exe'));
        if (await installedExe.exists()) {
          return installedExe.path;
        }
      } catch (_) {}

      // 2. Try standard C:\exiftool\exiftool.exe
      const cPath = r'C:\exiftool\exiftool.exe';
      if (await File(cPath).exists()) return cPath;
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(path.join(appDir.path, 'exiftool.exe'));
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

  Future<void> _writePhotoGpsToExif(List<PhotoEntry> photos) async {
    if (photos.isEmpty) return;
    setState(() {
      _isWritingExif = true;
      _exifTotal = photos.length;
      _exifProcessed = 0;
    });

    Directory? tempDir;
    File? csvFile;
    File? argFile;

    try {
      final exe = await _getExifToolExecutable();
      tempDir = await getTemporaryDirectory();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      csvFile = File(path.join(tempDir.path, 'exif_coords_$timestamp.csv'));
      argFile = File(path.join(tempDir.path, 'exif_paths_$timestamp.txt'));

      final csvBuf = StringBuffer();
      csvBuf.writeln(
          'SourceFile,GPSLatitude,GPSLatitudeRef,GPSLongitude,GPSLongitudeRef');

      final argBuf = StringBuffer();

      int validCount = 0;
      for (final photo in photos) {
        final loc = photo.assignedLatLng;
        if (loc == null) continue;

        final lat = loc.latitude.abs();
        final latRef = loc.latitude >= 0 ? 'N' : 'S';
        final lng = loc.longitude.abs();
        final lngRef = loc.longitude >= 0 ? 'E' : 'W';

        // Escape path for CSV
        final escapedPath = photo.file.path.replaceAll('"', '""');
        csvBuf.writeln('"$escapedPath",$lat,$latRef,$lng,$lngRef');

        // Remove ReadOnly attribute if present on Windows so ExifTool can edit file
        if (Platform.isWindows) {
          try { await Process.run('attrib', ['-r', photo.file.path]); } catch (_) {}
        }

        // Clean up any stale temp file from previous interrupted runs
        final tmpFile = File('${photo.file.path}_exiftool_tmp');
        if (await tmpFile.exists()) {
          try {
            if (Platform.isWindows) {
              await Process.run('attrib', ['-r', tmpFile.path]);
            }
            await tmpFile.delete();
          } catch (_) {}
        }

        argBuf.writeln(photo.file.path);
        validCount++;
      }

      if (validCount > 0) {
        await csvFile.writeAsString(csvBuf.toString(), flush: true);
        await argFile.writeAsString(argBuf.toString(), flush: true);

        setState(() {
          _exifTotal = validCount;
        });

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
            if (current != null && current > 0 && current <= validCount) {
              setState(() {
                _exifProcessed = current;
              });
            }
          }
        });

        final exitCode = await process.exitCode;
        debugPrint('[ExifTool Write Batch] exitCode=$exitCode');
        if (exitCode == 0) {
          setState(() {
            for (final photo in photos) {
              if (photo.assignedLatLng != null) {
                photo.isGpsModified = false;
              }
            }
          });
        }
      }
    } catch (e) {
      debugPrint('[ExifTool Write Batch Error] $e');
    } finally {
      try {
        if (csvFile != null && await csvFile.exists()) await csvFile.delete();
        if (argFile != null && await argFile.exists()) await argFile.delete();
      } catch (_) {}

      setState(() {
        _isWritingExif = false;
        _exifTotal = 0;
        _exifProcessed = 0;
      });
    }
  }

  bool _isImageFile(String path) {
    final ext = path.toLowerCase();
    return ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
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
  Future<void> _loadPhotosFromFiles(List<File> files,
      {bool isRestoringCache = false}) async {
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

    // Read EXIF in batch chunks using ExifTool CSV with -fast flag (ultra-fast disk I/O)
    await _batchReadExifWithExifTool(newEntries);
    if (!mounted) return;

    setState(() {
      _importCurrentStatus = 'Inserting photos into timeline...';
      _photos.addAll(newEntries);
    });

    _loadThumbnailsForPhotos(newEntries);

    // Save imported photo paths cache
    await _saveCachedPhotoPaths();

    // Auto-insert geotagged photos into timeline + rebuild assignments
    await _autoInsertGeotaggedPhotoPoints(newEntries);

    if (mounted) {
      setState(() {
        _isImportingPhotos = false;
      });
    }

    // Skip auto-nav / dialog when restoring cache on startup
    if (isRestoringCache) return;

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
            onPressed: () {
              Navigator.pop(ctx);
              _clearCachedPhotos();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All Photos'),
          ),
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
      _MacToastMessenger.of(context).showSnackBar(SnackBar(
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

    if (_selectedDate == null) return;
    final cdi = _currentDateInfo(appState);

    // If day has no timeline file, do NOT auto-create timeline track on maps
    if (cdi.filePath.isEmpty) {
      final pts = appState.activePaths[cdi.filePath] ?? [];
      _assignPhotosToTimelineItems(pts, tz);
      return;
    }

    final gpsEntries = newEntries.where((e) => e.gpsLatLng != null).toList();
    if (gpsEntries.isEmpty) {
      // No GPS photos — just rebuild assignments from existing track
      final pts = appState.activePaths[cdi.filePath] ?? [];
      _assignPhotosToTimelineItems(pts, tz);
      return;
    }
    List<LocationPoint> cur = cdi.filePath.isNotEmpty
        ? await LocationManager.loadLocationFile(cdi.filePath)
        : [];

    bool pointsAdded = false;
    for (final entry in gpsEntries) {
      if (entry.dateTaken != null &&
          entry.dateTaken!.year == cdi.date.year &&
          entry.dateTaken!.month == cdi.date.month &&
          entry.dateTaken!.day == cdi.date.day) {
        final ts =
            entry.dateTaken!.subtract(Duration(minutes: (tz * 60).toInt()));
        cur.add(LocationPoint(
          latitude: entry.gpsLatLng!.latitude,
          longitude: entry.gpsLatLng!.longitude,
          timestamp: ts,
        ));
        entry.addedToTimeline = true;
        pointsAdded = true;
      }
    }

    if (pointsAdded) {
      cur.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      await appState.saveListPoints(cdi, cur);
    }

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
    final filtered = _photos.where((p) {
      if (p.dateTaken == null) return true;
      return p.dateTaken!.year == sel.year &&
          p.dateTaken!.month == sel.month &&
          p.dateTaken!.day == sel.day;
    }).toList();
    filtered.sort((a, b) {
      if (a.dateTaken == null && b.dateTaken == null) return 0;
      if (a.dateTaken == null) return 1;
      if (b.dateTaken == null) return -1;
      return a.dateTaken!.compareTo(b.dateTaken!);
    });
    return filtered;
  }

  void _handlePhotoSelection(PhotoEntry photo) {
    setState(() {
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;

      if (isShift) {
        final currentPhotos = _currentDatePhotos;
        final clickedIdx = currentPhotos.indexOf(photo);
        int anchorIdx = -1;
        if (_shiftStartPhoto != null) {
          anchorIdx = currentPhotos.indexOf(_shiftStartPhoto!);
        } else if (_selectedPhoto != null) {
          anchorIdx = currentPhotos.indexOf(_selectedPhoto!);
          _shiftStartPhoto = _selectedPhoto;
        } else if (_selectedPhotoSet.isNotEmpty) {
          anchorIdx = currentPhotos.indexOf(_selectedPhotoSet.last);
          _shiftStartPhoto = _selectedPhotoSet.last;
        } else {
          _shiftStartPhoto = photo;
        }

        if (anchorIdx != -1 && clickedIdx != -1) {
          final start = min(anchorIdx, clickedIdx);
          final end = max(anchorIdx, clickedIdx);
          _selectedPhotoSet.clear();
          for (int i = start; i <= end; i++) {
            _selectedPhotoSet.add(currentPhotos[i]);
          }
        } else {
          _selectedPhotoSet.add(photo);
        }
        _selectedPhoto = photo;
      } else if (isCtrl) {
        _shiftStartPhoto = photo;
        if (_selectedPhotoSet.contains(photo)) {
          _selectedPhotoSet.remove(photo);
        } else {
          _selectedPhotoSet.add(photo);
        }
        _selectedPhoto = photo;
      } else {
        _shiftStartPhoto = photo;
        if (_selectedPhotoSet.length > 1 ||
            !_selectedPhotoSet.contains(photo)) {
          _selectedPhotoSet.clear();
          _selectedPhotoSet.add(photo);
        }
        _selectedPhoto = photo;
        _showPhotoGrid = false;
      }
    });
  }

  /// Clusters [points] into [TimelineItem]s, then assigns each [PhotoEntry]
  /// in [_currentDatePhotos] to the item whose time range contains [dateTaken].
  /// For photos without GPS, also computes [PhotoEntry.interpolatedLatLng].
  /// Stores result in [_timelineItemsWithPhotos] and calls [setState].
  void _assignPhotosToTimelineItems(List<LocationPoint> points, double tz) {
    final items = _clusterTimeline(points, tz);
    final datePhotos = _currentDatePhotos;
    debugPrint(
        '[TimelineAssign] tz=$tz points=${points.length} datePhotos=${datePhotos.length} totalItems=${items.length}');
    for (int idx = 0; idx < items.length; idx++) {
      final it = items[idx];
      debugPrint(
          '[TimelineAssign Item #$idx] type=${it.runtimeType} start=${it.startTime} end=${it.endTime}');
    }

    if (items.isEmpty && datePhotos.isNotEmpty) {
      final geotagged = datePhotos.where((p) => p.gpsLatLng != null).toList();
      final ungeotagged = datePhotos.where((p) => p.gpsLatLng == null).toList();

      LatLng center = const LatLng(10.776889, 106.700806);
      if (geotagged.isNotEmpty) {
        double avgLat = 0, avgLng = 0;
        for (final p in geotagged) {
          avgLat += p.gpsLatLng!.latitude;
          avgLng += p.gpsLatLng!.longitude;
        }
        center = LatLng(avgLat / geotagged.length, avgLng / geotagged.length);
      }

      final syntheticPlace = TimelinePlace(
        points: const [],
        center: center,
        startTime: datePhotos.first.dateTaken ?? DateTime.now(),
        endTime: datePhotos.last.dateTaken ?? DateTime.now(),
      );
      syntheticPlace.geotaggedPhotos = geotagged;
      syntheticPlace.ungeotaggedPhotos = ungeotagged;
      items.add(syntheticPlace);
    } else {
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

      for (final photo in datePhotos) {
        if (photo.dateTaken == null) {
          debugPrint(
              '[TimelineAssign Photo SKIP] ${photo.filename} dateTaken is null');
          continue;
        }

        // Compute interpolated position for ungeotagged photos using UTC time
        final photoUtc =
            photo.dateTaken!.subtract(Duration(minutes: (tz * 60).toInt()));

        if (photo.gpsLatLng == null && points.isNotEmpty) {
          photo.interpolatedLatLng =
              _interpolatePositionAtTime(photo.dateTaken!, points, tz);
        }

        if (items.isNotEmpty) {
          TimelineItem? best;
          String matchReason = '';

          // 1. Direct match: photo falls inside item time window [startTime, endTime] (both in UTC)
          for (int i = 0; i < items.length; i++) {
            final item = items[i];
            if (photoUtc.compareTo(item.startTime) >= 0 &&
                photoUtc.compareTo(item.endTime) <= 0) {
              best = item;
              matchReason = 'Direct window match inside item #$i';
              break;
            }
          }

          // 2. Boundary checks for photos taken before first item or after last item
          if (best == null) {
            if (photoUtc.isBefore(items.first.startTime)) {
              best = items.first;
              matchReason =
                  'Before first item start (${items.first.startTime}) -> assigned item #0';
            } else if (photoUtc.isAfter(items.last.endTime)) {
              best = items.last;
              matchReason =
                  'After last item end (${items.last.endTime}) -> assigned last item #${items.length - 1}';
            }
          }

          // 3. Gap matching: find nearest item boundary for photos taken in gaps between items
          if (best == null) {
            int minDiffMs = 999999999;
            for (int i = 0; i < items.length; i++) {
              final item = items[i];
              final diffStart = (photoUtc.millisecondsSinceEpoch -
                      item.startTime.millisecondsSinceEpoch)
                  .abs();
              final diffEnd = (photoUtc.millisecondsSinceEpoch -
                      item.endTime.millisecondsSinceEpoch)
                  .abs();
              final diff = min(diffStart, diffEnd);
              if (diff < minDiffMs) {
                minDiffMs = diff;
                best = item;
                matchReason =
                    'Gap nearest boundary match item #$i (diff=$diff)';
              }
            }
          }

          if (best != null) {
            final targetIdx = items.indexOf(best);
            debugPrint(
                '[TimelineAssign Photo MATCH] ${photo.filename} dateTaken=${photo.dateTaken} photoUtc=$photoUtc -> assignedToItem #$targetIdx ($matchReason)');
            if (photo.gpsLatLng != null) {
              if (best is TimelinePlace) best.geotaggedPhotos.add(photo);
              if (best is TimelinePath) best.geotaggedPhotos.add(photo);
            } else {
              if (best is TimelinePlace) best.ungeotaggedPhotos.add(photo);
              if (best is TimelinePath) best.ungeotaggedPhotos.add(photo);
            }
          }
        }
      }
    }

    if (mounted) setState(() => _timelineItemsWithPhotos = items);
  }

  // ── Photo helpers for Timeline tiles ──────────────────────────────────
  final Set<int> _expandedPhotoGrids = {};

  void _selectAllPhotosInItem(TimelineItem item) {
    final photos = (item is TimelinePlace)
        ? [...item.geotaggedPhotos, ...item.ungeotaggedPhotos]
        : (item is TimelinePath
            ? [...item.geotaggedPhotos, ...item.ungeotaggedPhotos]
            : <PhotoEntry>[]);
    if (photos.isEmpty) return;

    setState(() {
      _selectedPhotoSet
        ..clear()
        ..addAll(photos);
      _selectedPhoto = photos.first;
      _shiftStartPhoto = photos.first;
    });

    _focusTimelineForPhoto(photos.first);
  }




  Future<void> _geotagAllInItem(TimelineItem item) async {
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

    // Write EXIF GPS metadata directly into photo files on disk via ExifTool
    await _writePhotoGpsToExif(photosToTag);

    if (mounted) {
      _MacToastMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Applied & saved EXIF geotags for ${photosToTag.length} photo(s)'),
        backgroundColor: Colors.teal,
        duration: const Duration(seconds: 2),
      ));
    }

    if (!mounted) return;
    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final pts = appState.activePaths[_currentDateInfo(appState).filePath] ?? [];
    _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());
  }

  /// Modify Photo Geotag -> Snap photo GPS coordinate to timeline interpolated location
  Future<void> _modifyGeotagsFromTimelineInItem(TimelineItem item) async {
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

    final List<PhotoEntry> modifiedPhotos = [];
    setState(() {
      for (final photo in geotagged) {
        if (photo.dateTaken == null) continue;
        final LatLng? interpolated =
            _interpolatePositionAtTime(photo.dateTaken!, points, tz);
        if (interpolated != null) {
          photo.gpsLatLng = interpolated;
          photo.interpolatedLatLng = null;
          photo.addedToTimeline = true;
          modifiedPhotos.add(photo);
        }
      }
    });

    // Write updated EXIF GPS metadata directly into photo files on disk via ExifTool
    if (modifiedPhotos.isNotEmpty) {
      await _writePhotoGpsToExif(modifiedPhotos);
    }

    if (mounted) {
      _MacToastMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Updated & saved EXIF geotags for ${modifiedPhotos.length} photo(s)'),
        backgroundColor: Colors.teal,
        duration: const Duration(seconds: 2),
      ));
    }

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

    _MacToastMessenger.of(context).showSnackBar(SnackBar(
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
          _shiftStartPhoto = photo;
          if (_selectedPhotoSet.contains(photo)) {
            _selectedPhotoSet.remove(photo);
          } else {
            _selectedPhotoSet.add(photo);
          }
        } else if (HardwareKeyboard.instance.isShiftPressed) {
          final currentPhotos = _currentDatePhotos;
          final clickedIdx = currentPhotos.indexOf(photo);
          int anchorIdx = -1;
          if (_shiftStartPhoto != null) {
            anchorIdx = currentPhotos.indexOf(_shiftStartPhoto!);
          } else if (_selectedPhoto != null) {
            anchorIdx = currentPhotos.indexOf(_selectedPhoto!);
            _shiftStartPhoto = _selectedPhoto;
          } else if (_selectedPhotoSet.isNotEmpty) {
            anchorIdx = currentPhotos.indexOf(_selectedPhotoSet.last);
            _shiftStartPhoto = _selectedPhotoSet.last;
          } else {
            _shiftStartPhoto = photo;
          }

          if (anchorIdx != -1 && clickedIdx != -1) {
            final start = min(anchorIdx, clickedIdx);
            final end = max(anchorIdx, clickedIdx);
            _selectedPhotoSet.clear();
            for (int i = start; i <= end; i++) {
              _selectedPhotoSet.add(currentPhotos[i]);
            }
          } else {
            _selectedPhotoSet.add(photo);
          }
          _selectedPhoto = photo;
        } else {
          _selectedPhotoSet.clear();
          _selectedPhoto = (_selectedPhoto == photo) ? null : photo;
          _shiftStartPhoto = _selectedPhoto;
        }
      }),
      onSecondaryTapDown: (details) {
        _ignoreNextPlaceContextMenu = true;
        _showPhotoContextMenu(context, details.globalPosition, photo);
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: isSel ? 3.5 : 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6.5),
              child: Image.file(
                photo.thumbnailFile ?? photo.file,
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
          if (!photo.hasLensInfo)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showPhotoContextMenu(
      BuildContext context, Offset globalPosition, PhotoEntry photo) {
    if (!_selectedPhotoSet.contains(photo)) {
      setState(() {
        _selectedPhotoSet.clear();
        _selectedPhotoSet.add(photo);
        _selectedPhoto = photo;
      });
    }

    TimelineItem? parentItem;
    if (_timelineItemsWithPhotos != null) {
      for (final item in _timelineItemsWithPhotos!) {
        final g = (item is TimelinePlace)
            ? item.geotaggedPhotos
            : (item is TimelinePath ? item.geotaggedPhotos : <PhotoEntry>[]);
        final u = (item is TimelinePlace)
            ? item.ungeotaggedPhotos
            : (item is TimelinePath ? item.ungeotaggedPhotos : <PhotoEntry>[]);
        if (g.contains(photo) || u.contains(photo)) {
          parentItem = item;
          break;
        }
      }
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final relativeRect = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    final selectedCount = _selectedPhotoSet.length;

    showFadeMenu<String>(
      context: context,
      position: relativeRect,
      items: [
        if (parentItem != null) ...[
          PopupMenuItem(
            value: 'select_all_in_place',
            child: Row(
              children: [
                const Icon(Icons.select_all, size: 18, color: Colors.amber),
                const SizedBox(width: 8),
                Text(
                  'Select All Images of this ${parentItem is TimelinePlace ? "Place" : "Road Segment"}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: 'geotag_all',
          child: Row(
            children: [
              const Icon(Icons.pin_drop, size: 18, color: Colors.teal),
              const SizedBox(width: 8),
              Text(selectedCount > 1
                  ? 'Geotag All Selected ($selectedCount)'
                  : 'Geotag Photo'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'add_lens',
          child: Row(
            children: [
              const Icon(Icons.camera_alt, size: 18, color: Colors.deepPurple),
              const SizedBox(width: 8),
              Text(selectedCount > 1
                  ? 'Add Lens Metadata ($selectedCount)'
                  : 'Add Lens Metadata'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'remove_selected',
          child: Row(
            children: [
              const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
              const SizedBox(width: 8),
              Text(selectedCount > 1
                  ? 'Remove All Selected ($selectedCount)'
                  : 'Remove Photo'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'invert_select',
          child: Row(
            children: [
              Icon(Icons.swap_horiz, size: 18),
              SizedBox(width: 8),
              Text('Invert Selection'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'deselect_all',
          child: Row(
            children: [
              Icon(Icons.clear_all, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Deselect All'),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == null) return;
      if (val == 'select_all_in_place' && parentItem != null) {
        _selectAllPhotosInItem(parentItem);
      } else if (val == 'geotag_all') {
        _geotagSelectedPhotos();
      } else if (val == 'add_lens') {
        _showAddLensDialogForSelectedPhotos();
      } else if (val == 'remove_selected') {
        _removeSelectedPhotos();
      } else if (val == 'invert_select') {
        _invertPhotoSelection();
      } else if (val == 'deselect_all') {
        setState(() {
          _selectedPhotoSet.clear();
          _selectedPhoto = null;
        });
      }
    });
  }

  void _removeSelectedPhotos() {
    final targets = _selectedPhotoSet.isNotEmpty
        ? _selectedPhotoSet.toList()
        : (_selectedPhoto != null ? [_selectedPhoto!] : <PhotoEntry>[]);
    if (targets.isEmpty) return;

    setState(() {
      for (final p in targets) {
        _photos.remove(p);
        _selectedPhotoSet.remove(p);
      }
      if (_selectedPhoto != null && !_photos.contains(_selectedPhoto)) {
        _selectedPhoto =
            _selectedPhotoSet.isNotEmpty ? _selectedPhotoSet.first : null;
      }
    });

    _saveCachedPhotoPaths();

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final dateInfo = _currentDateInfo(appState);
    final pts = appState.activePaths[dateInfo.filePath] ?? [];
    _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());
  }

  void _invertPhotoSelection() {
    final currentPhotos = _currentDatePhotos;
    setState(() {
      final newSet = <PhotoEntry>{};
      for (final p in currentPhotos) {
        if (!_selectedPhotoSet.contains(p)) {
          newSet.add(p);
        }
      }
      _selectedPhotoSet.clear();
      _selectedPhotoSet.addAll(newSet);
      _selectedPhoto =
          _selectedPhotoSet.isNotEmpty ? _selectedPhotoSet.first : null;
    });
  }

  Future<void> _geotagSelectedPhotos() async {
    final targets = _selectedPhotoSet.toList();
    if (targets.isEmpty && _selectedPhoto != null) {
      targets.add(_selectedPhoto!);
    }
    if (targets.isEmpty) return;

    for (final p in targets) {
      if (p.interpolatedLatLng != null && p.gpsLatLng == null) {
        await _applyInterpolatedGeotag(p);
      }
    }
  }

  void _showAddLensDialogForSelectedPhotos() {
    final targets = _selectedPhotoSet.isNotEmpty
        ? _selectedPhotoSet.toList()
        : (_selectedPhoto != null ? [_selectedPhoto!] : <PhotoEntry>[]);
    if (targets.isEmpty) return;

    final settings = context.read<SettingsProvider>();
    LensTemplate? selectedTemplate =
        settings.lensTemplates.isNotEmpty ? settings.lensTemplates.first : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final templates = settings.lensTemplates;
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.camera_alt, color: Colors.deepPurple),
                const SizedBox(width: 8),
                Text('Add Lens Metadata (${targets.length} photos)'),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select a Lens Template to write EXIF Make, Model, Focal Length, and F-Number:',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 16),
                  if (templates.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: const Text(
                        'No lens templates saved. Click "+ Add New Lens Template" below to create your first lens!',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 250),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: templates.length,
                        itemBuilder: (c, i) {
                          final t = templates[i];
                          final isSelected = selectedTemplate?.id == t.id;
                          return ListTile(
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                color: isSelected
                                    ? Colors.deepPurple
                                    : Colors.grey.shade300,
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            leading: CircleAvatar(
                              backgroundColor: isSelected
                                  ? Colors.deepPurple
                                  : Colors.grey.shade200,
                              child: Icon(Icons.camera,
                                  size: 18,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.grey.shade700),
                            ),
                            title: Text(t.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 13)),
                            subtitle: Text(
                              '${t.make} ${t.model} • ${t.focalLength}mm f/${t.fNumber}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 18),
                                  tooltip: 'Edit Template',
                                  onPressed: () {
                                    _showEditCustomLensTemplateDialog(
                                        context, settings, t, (updated) {
                                      setModalState(() {
                                        selectedTemplate = updated;
                                      });
                                    });
                                  },
                                ),
                                if (isSelected)
                                  const Icon(Icons.check_circle,
                                      color: Colors.deepPurple),
                              ],
                            ),
                            onTap: () {
                              setModalState(() {
                                selectedTemplate = t;
                              });
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      _showAddCustomLensTemplateDialog(context, settings,
                          (newTemplate) {
                        setModalState(() {
                          selectedTemplate = newTemplate;
                        });
                      });
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add New Lens Template'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.deepPurple),
                onPressed: selectedTemplate == null
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _applyLensMetadataToPhotos(targets, selectedTemplate!);
                      },
                child: Text('Apply to ${targets.length} Photo(s)'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditCustomLensTemplateDialog(
      BuildContext context,
      SettingsProvider settings,
      LensTemplate template,
      Function(LensTemplate) onUpdated) {
    final nameCtrl = TextEditingController(text: template.name);
    final makeCtrl = TextEditingController(text: template.make);
    final modelCtrl = TextEditingController(text: template.model);
    final focalCtrl =
        TextEditingController(text: template.focalLength.toString());
    final fNumberCtrl =
        TextEditingController(text: template.fNumber.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Lens Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Preset Name (e.g. Carl Zeiss 135mm)'),
            ),
            TextField(
              controller: makeCtrl,
              decoration:
                  const InputDecoration(labelText: 'Make (e.g. Carl Zeiss)'),
            ),
            TextField(
              controller: modelCtrl,
              decoration:
                  const InputDecoration(labelText: 'Model (e.g. 135mm f/3.5)'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: focalCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Focal Length (mm)'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: fNumberCtrl,
                    decoration: const InputDecoration(labelText: 'F-Number'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final focal =
                  double.tryParse(focalCtrl.text) ?? template.focalLength;
              final fNum =
                  double.tryParse(fNumberCtrl.text) ?? template.fNumber;
              final updated = LensTemplate(
                id: template.id,
                name: nameCtrl.text.isNotEmpty
                    ? nameCtrl.text
                    : '${makeCtrl.text} ${modelCtrl.text}'.trim(),
                make: makeCtrl.text,
                model: modelCtrl.text,
                focalLength: focal,
                fNumber: fNum,
              );
              settings.updateLensTemplate(updated);
              onUpdated(updated);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showAddCustomLensTemplateDialog(BuildContext context,
      SettingsProvider settings, Function(LensTemplate) onCreated) {
    final nameCtrl = TextEditingController();
    final makeCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final focalCtrl = TextEditingController();
    final fNumberCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Lens Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Preset Name (e.g. Carl Zeiss 135mm)'),
            ),
            TextField(
              controller: makeCtrl,
              decoration:
                  const InputDecoration(labelText: 'Make (e.g. Carl Zeiss)'),
            ),
            TextField(
              controller: modelCtrl,
              decoration:
                  const InputDecoration(labelText: 'Model (e.g. 135mm f/3.5)'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: focalCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Focal Length (mm)'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: fNumberCtrl,
                    decoration: const InputDecoration(labelText: 'F-Number'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final focal = double.tryParse(focalCtrl.text) ?? 50.0;
              final fNum = double.tryParse(fNumberCtrl.text) ?? 2.8;
              final template = LensTemplate(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameCtrl.text.isNotEmpty
                    ? nameCtrl.text
                    : '${makeCtrl.text} ${modelCtrl.text}'.trim(),
                make: makeCtrl.text,
                model: modelCtrl.text,
                focalLength: focal,
                fNumber: fNum,
              );
              settings.addLensTemplate(template);
              onCreated(template);
              Navigator.pop(ctx);
            },
            child: const Text('Save & Select'),
          ),
        ],
      ),
    );
  }

  Future<void> _applyLensMetadataToPhotos(
      List<PhotoEntry> selectedPhotos, LensTemplate template) async {
    if (selectedPhotos.isEmpty) return;

    final photosToProcess = <PhotoEntry>[];
    String? globalConflictChoice;

    for (final photo in selectedPhotos) {
      if (photo.hasLensInfo) {
        if (globalConflictChoice == 'skip') {
          continue;
        } else if (globalConflictChoice == 'overwrite') {
          photosToProcess.add(photo);
          continue;
        }

        bool applyToAllRemaining = false;
        final result = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return StatefulBuilder(
              builder: (ctx, setModalState) {
                final currentLensStr = photo.lensModel ??
                    photo.lensMake ??
                    '${photo.focalLength}mm';
                return AlertDialog(
                  title: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange),
                      SizedBox(width: 8),
                      Text('Lens Metadata Conflict'),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Photo "${photo.filename}" already has lens metadata:\n'
                        '• Current Lens: $currentLensStr\n\n'
                        'Do you want to overwrite it with "${template.name}"?',
                        style: const TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'Apply choice to all remaining conflicts',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        value: applyToAllRemaining,
                        onChanged: (val) {
                          setModalState(() {
                            applyToAllRemaining = val ?? false;
                          });
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'skip'),
                      child: const Text('Skip'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'overwrite'),
                      child: const Text('Overwrite'),
                    ),
                  ],
                );
              },
            );
          },
        );

        if (result == 'overwrite') {
          photosToProcess.add(photo);
          if (applyToAllRemaining) {
            globalConflictChoice = 'overwrite';
          }
        } else {
          if (applyToAllRemaining) {
            globalConflictChoice = 'skip';
          }
        }
      } else {
        photosToProcess.add(photo);
      }
    }

    if (photosToProcess.isEmpty) {
      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No photos updated (all skipped).')),
        );
      }
      return;
    }

    await _writeLensMetadataWithExifTool(photosToProcess, template);
  }

  Future<void> _writeLensMetadataWithExifTool(
      List<PhotoEntry> photos, LensTemplate template) async {
    setState(() {
      _isWritingExif = true;
      _exifTotal = photos.length;
      _exifProcessed = 0;
    });

    try {
      final exe = await _getExifToolExecutable();
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final argFile = File(path.join(tempDir.path, 'lens_args_$timestamp.txt'));

      final argBuf = StringBuffer();
      argBuf.writeln('-Lens=${template.name}');
      argBuf.writeln('-LensModel=${template.model}');
      argBuf.writeln('-LensMake=${template.make}');
      argBuf.writeln('-FocalLength=${template.focalLength}');
      argBuf.writeln('-FNumber=${template.fNumber}');
      argBuf.writeln('-overwrite_original');

      for (final photo in photos) {
        // Remove ReadOnly attribute if present on Windows so ExifTool can edit file
        if (Platform.isWindows) {
          try { await Process.run('attrib', ['-r', photo.file.path]); } catch (_) {}
        }

        final tmpFile = File('${photo.file.path}_exiftool_tmp');
        if (await tmpFile.exists()) {
          try {
            if (Platform.isWindows) {
              await Process.run('attrib', ['-r', tmpFile.path]);
            }
            await tmpFile.delete();
          } catch (_) {}
        }
        argBuf.writeln(photo.file.path);
      }

      await argFile.writeAsString(argBuf.toString(), flush: true);

      final result = await Process.run(exe, ['-@', argFile.path]);

      if (result.exitCode == 0) {
        setState(() {
          for (final photo in photos) {
            photo.lensModel = template.model;
            photo.lensMake = template.make;
            photo.focalLength = template.focalLength;
            photo.fNumber = template.fNumber;
          }
        });
        _saveCachedPhotoPaths();

        if (mounted) {
          _MacToastMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Applied lens "${template.name}" to ${photos.length} photo(s)!',
              ),
              backgroundColor: Colors.teal,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception(result.stderr);
      }
    } catch (e) {
      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to write Lens EXIF: $e')),
        );
      }
    } finally {
      setState(() {
        _isWritingExif = false;
        _exifTotal = 0;
        _exifProcessed = 0;
      });
    }
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
      BuildContext context, TimelineItem item, int itemIndex, List<TimelineItem> allItems) {
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

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) {
        _showTimelineItemContextMenu(
            context, details.globalPosition, item, itemIndex, allItems);
      },
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: body,
      ),
    );
  }

  /// Promotes the interpolated position of [photo] to its GPS coordinate
  /// (in memory), moving it from ungeotagged → geotagged.
  Future<void> _applyInterpolatedGeotag(PhotoEntry photo) async {
    final loc = photo.interpolatedLatLng;
    if (loc == null) return;
    setState(() {
      photo.gpsLatLng = loc;
      photo.interpolatedLatLng = null;
      photo.addedToTimeline = true;
    });

    // Write new EXIF GPS tag directly into the image file on disk
    await _writePhotoGpsToExif([photo]);

    if (mounted) {
      _MacToastMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Geotag applied & saved to file EXIF: "${photo.filename}" '
                '(${loc.latitude.toStringAsFixed(5)}, '
                '${loc.longitude.toStringAsFixed(5)})'),
        backgroundColor: Colors.teal,
        duration: const Duration(seconds: 2),
      ));
    }

    // Rebuild so photo moves from ungeotagged row → geotagged row
    if (!mounted) return;
    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final pts = appState.activePaths[_currentDateInfo(appState).filePath] ?? [];
    _assignPhotosToTimelineItems(pts, settings.geotagTimezone.toDouble());
  }

  void _clusterSelectedPhotos() {
    if (_selectedPhotoSet.isEmpty) return;

    LatLng? baseLatLng;
    // 1. Tìm ảnh đầu tiên có tọa độ trong đống được chọn
    for (final photo in _selectedPhotoSet) {
      if (photo.assignedLatLng != null) {
        baseLatLng = photo.assignedLatLng;
        break;
      }
    }
    // 2. Thử dùng _selectedPhoto nếu không tìm thấy
    if (baseLatLng == null && _selectedPhoto != null) {
      baseLatLng = _selectedPhoto!.assignedLatLng;
    }
    // 3. Nếu vẫn không thấy, lấy tâm bản đồ hiện tại
    baseLatLng ??= _mapController.camera.center;

    final int maxPossibleClusters = min(10, _selectedPhotoSet.length);
    final clusterCountCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        double localJitter = _clusterJitterMeters;
        int localMaxClusters = min(_maxClusterGroups, maxPossibleClusters);
        if (localMaxClusters < 1) localMaxClusters = 1;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.pin_drop, color: Colors.teal),
                  SizedBox(width: 8),
                  Text('Cluster Photos',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gom ${_selectedPhotoSet.length} ảnh theo thời gian & vị trí timeline:',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  // Slider 1: Max Clusters Count
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Số cụm (cục) tối đa:',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      Text('$localMaxClusters cụm',
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.teal,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: localMaxClusters.toDouble().clamp(1.0, maxPossibleClusters.toDouble()),
                    min: 1.0,
                    max: maxPossibleClusters.toDouble(),
                    divisions: maxPossibleClusters > 1
                        ? maxPossibleClusters - 1
                        : 1,
                    label: '$localMaxClusters cụm',
                    onChanged: (val) {
                      setDialogState(() {
                        localMaxClusters = val.round();
                      });
                    },
                  ),
                  // Show text input when slider is at max
                  if (localMaxClusters >= maxPossibleClusters) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.edit, size: 14, color: Colors.teal),
                        const SizedBox(width: 6),
                        const Text('Nhập số cụm tuỳ ý:',
                            style: TextStyle(fontSize: 11, color: Colors.teal)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 64,
                          height: 32,
                          child: TextField(
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Colors.teal),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    const BorderSide(color: Colors.teal, width: 2),
                              ),
                            ),
                            controller: clusterCountCtrl,
                            onChanged: (val) {
                              final parsed = int.tryParse(val);
                              if (parsed != null && parsed >= 1) {
                                setDialogState(() {
                                  localMaxClusters = parsed;
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    '* Tự động gom các ảnh gần thời gian nhau thành $localMaxClusters cụm dọc theo lịch trình.',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  // Slider 2: Jitter Radius
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Bán kính nhiễu (Jitter):',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      Text('${localJitter.toStringAsFixed(1)} m',
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.teal,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: localJitter,
                    min: 0.0,
                    max: 100.0,
                    divisions: 100,
                    label: '${localJitter.toStringAsFixed(1)}m',
                    onChanged: (val) {
                      setDialogState(() {
                        localJitter = val;
                      });
                    },
                  ),
                  const Text(
                    '* 0m sẽ xếp chồng hoàn toàn. Giá trị lớn hơn sẽ nhích nhẹ ngẫu nhiên quanh tọa độ cụm.',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal.shade700),
                  onPressed: () {
                    setState(() {
                      _clusterJitterMeters = localJitter;
                      _maxClusterGroups = localMaxClusters;
                    });
                    Navigator.pop(context);
                    _executeClusterPhotos(baseLatLng!, localJitter, localMaxClusters);
                  },
                  child: const Text('Cluster'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _executeClusterPhotos(
      LatLng baseLatLng, double jitterMeters, int maxClusters) {
    if (_selectedPhotoSet.isEmpty) return;

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final dateInfo = _currentDateInfo(appState);
    final points = appState.activePaths[dateInfo.filePath] ?? [];
    final tz = settings.geotagTimezone.toDouble();

    final List<PhotoEntry> sortedPhotos = _selectedPhotoSet.toList();
    sortedPhotos.sort((a, b) {
      if (a.dateTaken != null && b.dateTaken != null) {
        return a.dateTaken!.compareTo(b.dateTaken!);
      }
      return a.filename.compareTo(b.filename);
    });

    final int targetClusterCount = min(maxClusters, sortedPhotos.length);
    final List<List<PhotoEntry>> photoGroups = [];

    if (targetClusterCount <= 1 || sortedPhotos.length <= 1) {
      photoGroups.add(sortedPhotos);
    } else {
      // Find top (targetClusterCount - 1) largest time gaps between adjacent photos
      final List<MapEntry<int, int>> timeGaps = [];
      for (int i = 0; i < sortedPhotos.length - 1; i++) {
        final t1 = sortedPhotos[i].dateTaken;
        final t2 = sortedPhotos[i + 1].dateTaken;
        final int gapMs = (t1 != null && t2 != null)
            ? (t2.difference(t1).inMilliseconds).abs()
            : 0;
        timeGaps.add(MapEntry(i, gapMs));
      }

      timeGaps.sort((a, b) => b.value.compareTo(a.value));
      final List<int> splitIndices = timeGaps
          .take(targetClusterCount - 1)
          .map((e) => e.key)
          .toList()
        ..sort();

      int currentStart = 0;
      for (final splitIdx in splitIndices) {
        photoGroups.add(sortedPhotos.sublist(currentStart, splitIdx + 1));
        currentStart = splitIdx + 1;
      }
      if (currentStart < sortedPhotos.length) {
        photoGroups.add(sortedPhotos.sublist(currentStart));
      }
    }

    final double maxDegreeJitter = jitterMeters / 111320.0;
    final random = Random();

    setState(() {
      for (int gIdx = 0; gIdx < photoGroups.length; gIdx++) {
        final group = photoGroups[gIdx];
        if (group.isEmpty) continue;

        // Determine cluster center for group g
        LatLng groupCenter = baseLatLng;
        final validDates = group
            .where((p) => p.dateTaken != null)
            .map((p) => p.dateTaken!)
            .toList();

        if (validDates.isNotEmpty) {
          final int avgEpoch = (validDates
                      .map((d) => d.millisecondsSinceEpoch)
                      .reduce((a, b) => a + b) /
                  validDates.length)
              .round();
          final avgTime = DateTime.fromMillisecondsSinceEpoch(avgEpoch);

          // Try to interpolate position on timeline for this group's average time
          if (points.isNotEmpty) {
            final interpolated =
                _interpolatePositionAtTime(avgTime, points, tz);
            if (interpolated != null) {
              groupCenter = interpolated;
            }
          }
        }

        // If no timeline interpolated point, check if any photos in group have existing assigned locations
        if (groupCenter == baseLatLng) {
          final existingLocs = group
              .where((p) => p.assignedLatLng != null)
              .map((p) => p.assignedLatLng!)
              .toList();
          if (existingLocs.isNotEmpty) {
            double avgLat = 0, avgLng = 0;
            for (final loc in existingLocs) {
              avgLat += loc.latitude;
              avgLng += loc.longitude;
            }
            groupCenter =
                LatLng(avgLat / existingLocs.length, avgLng / existingLocs.length);
          }
        }

        // 1 cluster → per-photo jitter (ảnh tản ra quanh tâm)
        // Multiple clusters → per-group jitter (ảnh cùng cụm chung 1 điểm, cụm khác nhau tách nhau)
        double groupLatJitter = 0.0;
        double groupLngJitter = 0.0;
        if (maxDegreeJitter > 0 && photoGroups.length > 1) {
          // Compute one offset for the whole group
          groupLatJitter = (random.nextDouble() - 0.5) * 2 * maxDegreeJitter;
          groupLngJitter = (random.nextDouble() - 0.5) * 2 * maxDegreeJitter;
        }

        for (final photo in group) {
          double latJitter = groupLatJitter;
          double lngJitter = groupLngJitter;
          if (maxDegreeJitter > 0 && photoGroups.length == 1) {
            // Single cluster: each photo gets its own random jitter
            latJitter = (random.nextDouble() - 0.5) * 2 * maxDegreeJitter;
            lngJitter = (random.nextDouble() - 0.5) * 2 * maxDegreeJitter;
          }
          photo.gpsLatLng = LatLng(
            groupCenter.latitude + latJitter,
            groupCenter.longitude + lngJitter,
          );
          photo.interpolatedLatLng = null;
          photo.isGpsModified = true;
        }
      }
    });

    _assignPhotosToTimelineItems(points, tz);

    _MacToastMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Clustered ${_selectedPhotoSet.length} photo(s) into ${photoGroups.length} cluster(s) — tap "Save All" to write EXIF',
        ),
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
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

      final points = rawDayPoints;
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
    // Khi đang multi-select, tăng ngưỡng hit 2.5x để dễ bắt ảnh hơn
    final effectiveThreshold =
        _selectedPhotoSet.length > 1 ? photoThreshold * 2.5 : photoThreshold;
    final photoThresholdSq = effectiveThreshold * effectiveThreshold;
    PhotoEntry? hitPhoto;
    double hitPhotoDistSq = double.infinity;

    // Khi multi-select: chỉ hit-test ảnh trong set, bỏ qua ảnh chưa select
    final photosToTest =
        _selectedPhotoSet.length > 1 ? _selectedPhotoSet.toList() : _photos;

    for (final photo in photosToTest) {
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
      final photoToHit = hitPhoto;
      setState(() {
        _draggingPhoto = photoToHit;
        _isDraggingPhoto = true;
        _selectedPhoto = photoToHit;
        _photoDragStartLatLng = tapLatLng;
        _initialPhotoLocations.clear();

        final photosToDrag = (_selectedPhotoSet.contains(photoToHit) &&
                _selectedPhotoSet.isNotEmpty)
            ? _selectedPhotoSet
            : {photoToHit};

        for (final photo in photosToDrag) {
          final loc = photo.assignedLatLng;
          if (loc != null) {
            _initialPhotoLocations[photo] = loc;
          }
        }
      });
      return; // consume event — don't edit route
    }

    // Nếu đang multi-select mà tap không trúng ảnh nào → vẫn block event
    // để tránh vô tình kéo path khi đang cầm đống ảnh
    if (_selectedPhotoSet.length > 1 && canDragOrEdit) {
      return;
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
        _pushUndoState(allPoints);

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

    if (_isDraggingPhoto &&
        _draggingPhoto != null &&
        _photoDragStartLatLng != null) {
      final dLat = moveLatLng.latitude - _photoDragStartLatLng!.latitude;
      final dLng = moveLatLng.longitude - _photoDragStartLatLng!.longitude;

      setState(() {
        _initialPhotoLocations.forEach((photo, startLoc) {
          final moved =
              LatLng(startLoc.latitude + dLat, startLoc.longitude + dLng);
          photo.gpsLatLng = moved;
          photo.interpolatedLatLng = moved;
          photo.isGpsModified = true;
        });
      });
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
            _MacToastMessenger.of(context).showSnackBar(
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

          final targetIdx =
              existingIdx != -1 ? existingIdx : _draggedHoverDotInsertIndex!;
          final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
          if (isShiftPressed) {
            int anchorStart = 0;
            for (int k = targetIdx; k >= 0; k--) {
              final nearestOld = _findNearestOldPoint(updated[k], dayPoints);
              final dist = GeoUtils.distanceBetween(
                  updated[k].latLng, nearestOld.latLng);
              if (dist < 15.0) {
                anchorStart = k;
                break;
              }
            }

            int anchorEnd = updated.length - 1;
            for (int m = targetIdx; m < updated.length; m++) {
              final nearestOld = _findNearestOldPoint(updated[m], dayPoints);
              final dist = GeoUtils.distanceBetween(
                  updated[m].latLng, nearestOld.latLng);
              if (dist < 15.0) {
                anchorEnd = m;
                break;
              }
            }

            if (anchorEnd > anchorStart + 1) {
              _interpolatePointsRange(updated, anchorStart, anchorEnd);
            }
          }

          // Repaint immediately with 0ms latency, then save to disk async
          appState.updateActivePathInMemory(dateInfo, updated);

          final settings = context.read<SettingsProvider>();
          final tz = settings.geotagTimezone.toDouble();
          setState(() {
            _assignPhotosToTimelineItems(updated, tz);
          });

          if (_autoSnapOnDrag && _draggedHoverDotSegment != null && mounted) {
            _snapSegmentToRoads(context, appState, dateInfo, updated,
                _draggedHoverDotSegment!, newPoint.latLng,
                forceEvenTimeDistribution: isShiftPressed);
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
      final draggedCount = _initialPhotoLocations.length;
      final targetLoc = _draggingPhoto?.assignedLatLng;

      setState(() {
        _isDraggingPhoto = false;
        _draggingPhoto = null;
        _initialPhotoLocations.clear();
        _photoDragStartLatLng = null;
      });

      // Re-assign photos to timeline items after drag completes
      final appState = context.read<AppStateProvider>();
      final settings = context.read<SettingsProvider>();
      final dateInfo = _currentDateInfo(appState);
      final points = appState.activePaths[dateInfo.filePath] ?? [];
      _assignPhotosToTimelineItems(points, settings.geotagTimezone.toDouble());

      if (targetLoc != null && context.mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Moved $draggedCount photo(s) to ${targetLoc.latitude.toStringAsFixed(5)}, ${targetLoc.longitude.toStringAsFixed(5)} — tap "Save All" to write EXIF',
            ),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (_isDraggingPoint) {
      final appState = context.read<AppStateProvider>();
      final settings = context.read<SettingsProvider>();
      final double tz = settings.geotagTimezone.toDouble();
      if (_selectedPointIndex != null) {
        appState.redistributeTimestampsAroundPoint(_selectedPointIndex!);
        final info = _currentDateInfo(appState);
        final pts = appState.activePaths[info.filePath] ?? [];
        _assignPhotosToTimelineItems(pts, tz);
      }
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
      _MacToastMessenger.of(context).showSnackBar(
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
    final tz = settings.geotagTimezone.toDouble();
    setState(() {
      _selectedPointIndex = nearestIdx;
      _assignPhotosToTimelineItems(finalPoints, tz);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Favorite Roads — save, list, snap & redistribute timestamps
  // ─────────────────────────────────────────────────────────────────────────

  void _openFavoriteRoadsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final settings = context.watch<SettingsProvider>();
          final favorites = settings.favoriteRoads;

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.star, color: Colors.amber),
                SizedBox(width: 8),
                Text('Favorite Roads Collection'),
              ],
            ),
            content: SizedBox(
              width: 500,
              height: 400,
              child: favorites.isEmpty
                  ? const Center(
                      child: Text(
                        'No favorite roads saved yet.\n\nClick "Add to Favorite Roads" in any road segment menu to save routes here!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.separated(
                      itemCount: favorites.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final fav = favorites[idx];
                        final distKm =
                            (fav.distanceMeters / 1000).toStringAsFixed(2);
                        final dateStr = DateFormat('yyyy-MM-dd HH:mm')
                            .format(fav.createdAt);

                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.amber,
                            child: Icon(Icons.route,
                                color: Colors.white, size: 20),
                          ),
                          title: Text(fav.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                              '${fav.points.length} points • $distKm km • Saved $dateStr'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red),
                            tooltip: 'Delete Favorite Road',
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Delete Favorite Road'),
                                  content: Text(
                                      'Are you sure you want to remove "${fav.name}" from your favorite roads?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );

                              if (confirm == true) {
                                await settings.removeFavoriteRoad(fav.id);
                                setModalState(() {});
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addSegmentToFavorites(
      BuildContext context, TimelinePath item) async {
    final settings = context.read<SettingsProvider>();
    final defaultName =
        'Road (${(item.distance / 1000).toStringAsFixed(1)} km, ${item.points.length} pts)';
    final controller = TextEditingController(text: defaultName);

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.star, color: Colors.amber),
            SizedBox(width: 8),
            Text('Add to Favorite Roads'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Save this road geometry to your Favorite Roads collection for quick snapping later:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Favorite Road Name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save to Favorites'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      final road = FavoriteRoad(
        id: 'fav_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        points: item.points.map((p) => p.latLng).toList(),
        distanceMeters: item.distance,
        createdAt: DateTime.now(),
      );
      await settings.addFavoriteRoad(road);
      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved "$name" to Favorite Roads!'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _showSnapToFavoriteDialog(
      BuildContext context, TimelinePath item) async {
    final settings = context.read<SettingsProvider>();
    final favorites = settings.favoriteRoads;

    if (favorites.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.star_outline, color: Colors.amber),
              SizedBox(width: 8),
              Text('No Favorite Roads Saved'),
            ],
          ),
          content: const Text(
            'You have no saved Favorite Roads yet.\n\nUse "Add to Favorite Roads" on any road segment menu to save a route first!',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final selectedRoad = await showDialog<FavoriteRoad>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.star, color: Colors.amber),
            SizedBox(width: 8),
            Text('Snap to Favorite Road'),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select a Favorite Road to snap and replace this road segment geometry. Timestamps will be automatically redistributed proportionally by distance:',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: favorites.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, idx) {
                    final fav = favorites[idx];
                    final distKm =
                        (fav.distanceMeters / 1000).toStringAsFixed(2);
                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Colors.amber,
                        child: Icon(Icons.route, color: Colors.white, size: 20),
                      ),
                      title: Text(fav.name,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle:
                          Text('${fav.points.length} points • $distKm km'),
                      onTap: () => Navigator.pop(ctx, fav),
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
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedRoad != null) {
      await _snapSegmentToFavoriteRoad(context, item, selectedRoad);
    }
  }

  Future<void> _snapSegmentToFavoriteRoad(
      BuildContext context, TimelinePath item, FavoriteRoad favRoad) async {
    if (favRoad.points.length < 2) return;

    final appState = context.read<AppStateProvider>();
    final settings = context.read<SettingsProvider>();
    final double tz = settings.geotagTimezone.toDouble();
    final dateInfo = _currentDateInfo(appState);
    final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];

    // 1. Endpoint Similarity Check
    if (item.points.isNotEmpty) {
      final startPt = item.points.first.latLng;
      final endPt = item.points.last.latLng;
      final startDiff = GeoUtils.distanceBetween(favRoad.points.first, startPt);
      final endDiff = GeoUtils.distanceBetween(favRoad.points.last, endPt);

      // If endpoints differ by > 1.5 km (1500m), show warning modal
      if (startDiff > 1500 || endDiff > 1500) {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange),
                SizedBox(width: 8),
                Text('Start/End Points Mismatch'),
              ],
            ),
            content: Text(
              'The start/end points of "${favRoad.name}" differ significantly from this road segment:\n\n'
              '• Start distance diff: ${(startDiff / 1000).toStringAsFixed(2)} km\n'
              '• End distance diff: ${(endDiff / 1000).toStringAsFixed(2)} km\n\n'
              'Only favorite roads with matching start and end points should be snapped. Do you want to snap anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Snap Anyway'),
              ),
            ],
          ),
        );

        if (confirm != true) return;
      }
    }

    // Backup current segment for undo
    final segmentKey = _getSegmentKey(item.startTime, item.endTime);
    _unsnappedSegmentBackups[segmentKey] =
        List<LocationPoint>.from(item.points);

    // 2. Intermediate Places Check
    // Find any TimelinePlace items for this day that sit strictly inside [item.startTime, item.endTime]
    final allItems = _clusterTimeline(dayPoints, tz);
    final placesInBetween = allItems
        .whereType<TimelinePlace>()
        .where((p) =>
            (p.startTime.isAfter(item.startTime) ||
                p.startTime.isAtSameMomentAs(item.startTime)) &&
            (p.endTime.isBefore(item.endTime) ||
                p.endTime.isAtSameMomentAs(item.endTime)))
        .toList();

    final List<LocationPoint> newSegmentPoints = [];
    final favPts = favRoad.points;

    if (placesInBetween.isEmpty) {
      // Direct snap whole favorite road
      final List<double> distances = [0.0];
      double totalDist = 0.0;
      for (int i = 0; i < favPts.length - 1; i++) {
        final d = GeoUtils.distanceBetween(favPts[i], favPts[i + 1]);
        totalDist += d;
        distances.add(totalDist);
      }

      final timeStart = item.startTime;
      final timeEnd = item.endTime;
      final totalDuration = timeEnd.difference(timeStart);

      for (int i = 0; i < favPts.length; i++) {
        final progress = totalDist > 0
            ? distances[i] / totalDist
            : (i / (favPts.length - 1));
        final addMs = (totalDuration.inMilliseconds * progress).toInt();
        newSegmentPoints.add(LocationPoint(
          latitude: favPts[i].latitude,
          longitude: favPts[i].longitude,
          timestamp: timeStart.add(Duration(milliseconds: addMs)),
        ));
      }
    } else {
      // Intermediate places exist! Project each place onto favPts and split segments cleanly around place start & end times
      placesInBetween.sort((a, b) => a.startTime.compareTo(b.startTime));

      // Project places onto favPts to get split indices
      final List<int> splitIndices = [];
      final List<LatLng> splitPoints = [];

      for (final place in placesInBetween) {
        final proj = GeoUtils.findClosestOnPolyline(place.center, favPts);
        splitIndices.add(proj.insertIndex);
        splitPoints.add(proj.projectedPoint);
      }

      DateTime currentSegStartTime = item.startTime;
      int currentFavIndex = 0;

      for (int k = 0; k < placesInBetween.length; k++) {
        final place = placesInBetween[k];
        final splitIdx = splitIndices[k];
        final splitPt = splitPoints[k];

        // 1. Build Road Sub-segment before place (from currentSegStartTime to place.startTime)
        final List<LatLng> subFavPts = [];
        for (int i = currentFavIndex; i <= splitIdx; i++) {
          subFavPts.add(favPts[i]);
        }
        subFavPts.add(splitPt);

        if (subFavPts.length >= 2) {
          final List<double> subDists = [0.0];
          double subTotalD = 0.0;
          for (int i = 0; i < subFavPts.length - 1; i++) {
            final d = GeoUtils.distanceBetween(subFavPts[i], subFavPts[i + 1]);
            subTotalD += d;
            subDists.add(subTotalD);
          }

          final subDuration = place.startTime.difference(currentSegStartTime);
          for (int i = 0; i < subFavPts.length; i++) {
            final progress = subTotalD > 0
                ? subDists[i] / subTotalD
                : (i / (subFavPts.length - 1));
            final addMs = (subDuration.inMilliseconds * progress).toInt();
            newSegmentPoints.add(LocationPoint(
              latitude: subFavPts[i].latitude,
              longitude: subFavPts[i].longitude,
              timestamp: currentSegStartTime.add(Duration(milliseconds: addMs)),
            ));
          }
        }

        // 2. Add Place stay points (from place.startTime to place.endTime)
        newSegmentPoints.add(LocationPoint(
          latitude: splitPt.latitude,
          longitude: splitPt.longitude,
          timestamp: place.startTime,
        ));
        newSegmentPoints.add(LocationPoint(
          latitude: splitPt.latitude,
          longitude: splitPt.longitude,
          timestamp: place.endTime,
        ));

        // Advance to after place
        currentSegStartTime = place.endTime;
        currentFavIndex = splitIdx + 1;
      }

      // 3. Build Final Road Sub-segment after last place (from place.endTime to item.endTime)
      final List<LatLng> finalSubPts = [
        if (splitPoints.isNotEmpty) splitPoints.last,
        for (int i = currentFavIndex; i < favPts.length; i++) favPts[i],
      ];

      if (finalSubPts.length >= 2) {
        final List<double> subDists = [0.0];
        double subTotalD = 0.0;
        for (int i = 0; i < finalSubPts.length - 1; i++) {
          final d =
              GeoUtils.distanceBetween(finalSubPts[i], finalSubPts[i + 1]);
          subTotalD += d;
          subDists.add(subTotalD);
        }

        final subDuration = item.endTime.difference(currentSegStartTime);
        for (int i = 0; i < finalSubPts.length; i++) {
          final progress = subTotalD > 0
              ? subDists[i] / subTotalD
              : (i / (finalSubPts.length - 1));
          final addMs = (subDuration.inMilliseconds * progress).toInt();
          newSegmentPoints.add(LocationPoint(
            latitude: finalSubPts[i].latitude,
            longitude: finalSubPts[i].longitude,
            timestamp: currentSegStartTime.add(Duration(milliseconds: addMs)),
          ));
        }
      }
    }

    // Find start & end indices in dayPoints
    int startIdx = -1;
    int endIdx = -1;
    if (item.points.isNotEmpty) {
      final pFirst = item.points.first;
      final pLast = item.points.last;
      startIdx = dayPoints.indexWhere((p) => p.timestamp == pFirst.timestamp);
      endIdx = dayPoints.indexWhere((p) => p.timestamp == pLast.timestamp);
    }

    List<LocationPoint> updatedDayPoints = [];
    if (startIdx != -1 && endIdx != -1 && startIdx <= endIdx) {
      updatedDayPoints = [
        ...dayPoints.sublist(0, startIdx),
        ...newSegmentPoints,
        ...dayPoints.sublist(endIdx + 1),
      ];
    } else {
      updatedDayPoints = List<LocationPoint>.from(dayPoints);
    }

    appState.activePaths[dateInfo.filePath] = updatedDayPoints;
    await appState.saveListPoints(dateInfo, updatedDayPoints);
    _assignPhotosToTimelineItems(updatedDayPoints, tz);

    if (mounted) {
      _MacToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Snapped segment to "${favRoad.name}"! Road 1 ends at place start, Road 2 resumes at place end.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleImportedLocationFiles(
      BuildContext context,
      AppStateProvider appState,
      SettingsProvider settings,
      List<File> files) async {
    final double tz = settings.geotagTimezone.toDouble();
    List<LocationPoint> allImportedPoints = [];

    for (final file in files) {
      try {
        final pts = await LocationManager.loadLocationFile(file.path);
        if (pts.isNotEmpty) {
          allImportedPoints.addAll(pts);
        }
      } catch (e) {
        debugPrint('Failed to load dropped timeline file ${file.path}: $e');
      }
    }

    if (allImportedPoints.isNotEmpty) {
      // Save points to app storage active & original directories
      await appState.saveImportedPoints(allImportedPoints, 'timeline');

      // Select newly imported date
      final importedDate = DateTime.utc(
        allImportedPoints.first.timestamp.year,
        allImportedPoints.first.timestamp.month,
        allImportedPoints.first.timestamp.day,
      );

      final dateInfo = appState.allDates.firstWhere(
        (d) =>
            d.date.year == importedDate.year &&
            d.date.month == importedDate.month &&
            d.date.day == importedDate.day,
        orElse: () => DateInfo(
          date: importedDate,
          pointCount: allImportedPoints.length,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'timeline',
          hasTimelineBackup: true,
          hasGpxBackup: false,
        ),
      );

      final newPts = appState.activePaths[dateInfo.filePath] ??
          await LocationManager.loadLocationFile(dateInfo.filePath);
      appState.activePaths[dateInfo.filePath] = newPts;

      setState(() {
        _selectedDate = dateInfo.date;
      });

      _assignPhotosToTimelineItems(newPts, tz);

      if (newPts.isNotEmpty) {
        _animatedMapMove(newPts.first.latLng, 14.5);
      }

      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported ${files.length} timeline file(s) with ${allImportedPoints.length} points!',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String _formatPointTime(DateTime utcTime, double timezoneOffset,
      {bool includeDate = false}) {
    final localTime =
        utcTime.toUtc().add(Duration(minutes: (timezoneOffset * 60).toInt()));
    if (includeDate || _chartMode != 'daily') {
      return DateFormat('HH:mm dd/MM').format(localTime);
    }
    if (_selectedDate != null) {
      if (localTime.year != _selectedDate!.year ||
          localTime.month != _selectedDate!.month ||
          localTime.day != _selectedDate!.day) {
        return DateFormat('HH:mm dd/MM').format(localTime);
      }
    }
    return DateFormat('HH:mm').format(localTime);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECTION: Point dialogs — add point, edit point
  // ─────────────────────────────────────────────────────────────────────────

  // ignore: unused_element
  void _openAddPointDialog(BuildContext context, AppStateProvider appState,
      DateInfo dateInfo, List<LocationPoint> currentPoints) {
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();
    final timeCtrl =
        TextEditingController(text: DateFormat('HH:mm').format(DateTime.now()));

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
                if (timeParts.length < 2) throw Exception('Format error');
                final hr = int.parse(timeParts[0]);
                final min = int.parse(timeParts[1]);
                final sec = timeParts.length > 2 ? int.parse(timeParts[2]) : 0;

                final settings = context.read<SettingsProvider>();
                final offset = settings.geotagTimezone.toDouble();

                final localDate = DateTime(
                  dateInfo.date.year,
                  dateInfo.date.month,
                  dateInfo.date.day,
                  hr,
                  min,
                  sec,
                );
                final utcDate = localDate
                    .subtract(Duration(minutes: (offset * 60).toInt()))
                    .toUtc();

                final newPoint = LocationPoint(
                  latitude: lat,
                  longitude: lng,
                  timestamp: utcDate,
                );

                final allDayPoints = List<LocationPoint>.from(
                    appState.activePaths[dateInfo.filePath] ?? []);
                _pushUndoState(allDayPoints);
                allDayPoints.add(newPoint);
                allDayPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

                await appState.saveListPoints(dateInfo, allDayPoints);
                _loadPointsForSelectedDate();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (context.mounted) {
                  _MacToastMessenger.of(context).showSnackBar(
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

                final allDayPoints = List<LocationPoint>.from(
                    appState.activePaths[dateInfo.filePath] ?? []);
                _pushUndoState(allDayPoints);

                int targetIdx = allDayPoints.indexWhere((p) =>
                    p == pt ||
                    (p.timestamp.millisecondsSinceEpoch ==
                            pt.timestamp.millisecondsSinceEpoch &&
                        (p.latitude - pt.latitude).abs() < 0.00001 &&
                        (p.longitude - pt.longitude).abs() < 0.00001));

                if (targetIdx == -1) {
                  // Fallback: match by closest timestamp within 5 seconds
                  int closestIdx = -1;
                  int minDiff = 999999999;
                  for (int i = 0; i < allDayPoints.length; i++) {
                    final diff =
                        (allDayPoints[i].timestamp.millisecondsSinceEpoch -
                                pt.timestamp.millisecondsSinceEpoch)
                            .abs();
                    if (diff < minDiff && diff < 5000) {
                      minDiff = diff;
                      closestIdx = i;
                    }
                  }
                  targetIdx = closestIdx;
                }

                if (targetIdx != -1) {
                  allDayPoints[targetIdx] = updatedPoint;
                } else {
                  allDayPoints.add(updatedPoint);
                }

                allDayPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

                // Instantly update active paths in memory (0ms lag!)
                setState(() {
                  appState.activePaths[dateInfo.filePath] = allDayPoints;
                });
                _saveWithIndicator(appState, dateInfo, allDayPoints);
                _loadPointsForSelectedDate();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (context.mounted) {
                  _MacToastMessenger.of(context).showSnackBar(
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
                                items: () {
                                  final currentYear = DateTime.now().year;
                                  final selectedYear = _selectedDate?.year;
                                  int minYear = 1970;
                                  int maxYear = currentYear;
                                  if (selectedYear != null) {
                                    if (selectedYear < minYear) minYear = selectedYear;
                                    if (selectedYear > maxYear) maxYear = selectedYear;
                                  }
                                  return List.generate(
                                          maxYear - minYear + 1,
                                          (i) => minYear + i)
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
                                      .toList();
                                }(),
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
            chartMode: _chartMode,
            onModeChanged: (mode) {
              setState(() {
                _chartMode = mode;
              });
            },
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
                                  ? (_chartMode == 'monthly'
                                      ? 'Monthly Timeline'
                                      : (_chartMode == 'yearly'
                                          ? 'Yearly Timeline'
                                          : 'Timeline'))
                                  : 'Track Details (${points.length} pts)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            // Snap Roads Secondary Button (to the left of Auto Snap)
                            FilledButton.tonalIcon(
                              onPressed: isEditing || dateInfo.filePath.isEmpty
                                  ? null
                                  : () async {
                                      await appState.snapToRoads(dateInfo);
                                      _loadPointsForSelectedDate();
                                      if (context.mounted) {
                                        _MacToastMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'Snapped timeline to roads!'),
                                          ),
                                        );
                                      }
                                    },
                              icon: Icon(
                                Icons.alt_route,
                                size: 16,
                                color: dateInfo.state == 'snapped'
                                    ? Colors.green.shade800
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer,
                              ),
                              label: Text(
                                'Snap',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: dateInfo.state == 'snapped'
                                      ? Colors.green.shade800
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: dateInfo.state == 'snapped'
                                    ? Colors.green.shade100
                                    : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer,
                              ),
                            ),
                            const SizedBox(width: 8),
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
                                        _MacToastMessenger.of(context)
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
                              icon: const Icon(Icons.star, color: Colors.amber),
                              onPressed: () =>
                                  _openFavoriteRoadsDialog(context),
                              tooltip: 'Favorite Roads',
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
                                  controller: _timelineScrollController,
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
                                                    final targetPt =
                                                        points[idx];
                                                    final allDayPoints = List<
                                                            LocationPoint>.from(
                                                        appState.activePaths[
                                                                dateInfo
                                                                    .filePath] ??
                                                            []);
                                                    allDayPoints.removeWhere((p) =>
                                                        p == targetPt ||
                                                        (p.latitude ==
                                                                targetPt
                                                                    .latitude &&
                                                            p.longitude ==
                                                                targetPt
                                                                    .longitude &&
                                                            p.timestamp ==
                                                                targetPt
                                                                    .timestamp));
                                                    await appState
                                                        .saveListPoints(
                                                            dateInfo,
                                                            allDayPoints);
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
            borderStrokeWidth: 1.0,
            borderColor: Colors.grey.shade900.withValues(alpha: 0.3),
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
            borderStrokeWidth: 1.5,
            borderColor: Colors.deepOrange.shade900,
          ),
        );
      } else if (_viewAsPath && timelineItems.isNotEmpty) {
        // Render each TimelinePath as a separate polyline with conditional colors/thickness
        for (int idx = 0; idx < timelineItems.length; idx++) {
          final item = timelineItems[idx];
          if (item is TimelinePath && item.points.isNotEmpty) {
            Color lineColor;
            double width;

            final hasTimelineSelection = (_selectedTimelineItemIndex != null &&
                _selectedTimelineItemIndex! < timelineItems.length);

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

            final outlineColor = (lineColor.a < 1.0)
                ? Colors.purple.shade900.withValues(alpha: lineColor.a)
                : Colors.purple.shade900;

            polylines.add(
              Polyline(
                points: pathLatLngs,
                strokeWidth: width,
                color: lineColor,
                borderStrokeWidth: 1.5,
                borderColor: outlineColor,
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
            borderStrokeWidth: 1.5,
            borderColor: Colors.purple.shade900,
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
                        DateFormat('HH:mm').format(localHoverTime),
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
          onTap: () => _handlePhotoSelection(photo),
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
      isDraggingPhoto: _isDraggingPhoto,
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

  DateTime? _lastHandledImportDate;

  @override
  Widget build(BuildContext context) {
    // Refresh activeState mỗi frame để tránh bị null sau hot reload
    activeState = this;
    final appState = context.watch<AppStateProvider>();
    final settings = context.watch<SettingsProvider>();
    final isEditing = appState.isEditing;
    final timeOffset = settings.geotagTimezone.toDouble();

    // Reactive update when a new timeline date is imported from ImportExportScreen or DropTarget
    if (appState.lastImportedDate != null &&
        appState.lastImportedDate != _lastHandledImportDate) {
      _lastHandledImportDate = appState.lastImportedDate;
      final importedDate = DateTime.utc(
        appState.lastImportedDate!.year,
        appState.lastImportedDate!.month,
        appState.lastImportedDate!.day,
      );
      _selectedDate = importedDate;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadPointsForSelectedDate();
      });
    }

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

    List<LocationPoint> pointsToShow;
    if (isEditing) {
      pointsToShow = appState.editingPoints;
    } else if (_chartMode == 'monthly') {
      final monthDates = appState.allDates.where((d) =>
          _selectedDate != null &&
          d.date.year == _selectedDate!.year &&
          d.date.month == _selectedDate!.month &&
          d.filePath.isNotEmpty);
      final List<LocationPoint> allMonthPts = [];
      for (final d in monthDates) {
        final pts = appState.activePaths[d.filePath] ?? [];
        allMonthPts.addAll(pts);
      }
      allMonthPts.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      pointsToShow = allMonthPts;
    } else if (_chartMode == 'yearly') {
      final yearDates = appState.allDates.where((d) =>
          _selectedDate != null &&
          d.date.year == _selectedDate!.year &&
          d.filePath.isNotEmpty);
      final List<LocationPoint> allYearPts = [];
      for (final d in yearDates) {
        final pts = appState.activePaths[d.filePath] ?? [];
        allYearPts.addAll(pts);
      }
      allYearPts.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      pointsToShow = allYearPts;
    } else {
      pointsToShow =
          _getPointsForSelectedDay(appState, _selectedDate!, timeOffset);
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDraggingPhotoOver = true),
      onDragExited: (_) => setState(() => _isDraggingPhotoOver = false),
      onDragDone: (detail) async {
        setState(() => _isDraggingPhotoOver = false);
        if (context.read<AppStateProvider>().currentIndex != 5) return;
        final droppedFiles = detail.files.map((f) => File(f.path)).toList();

        const locationExtensions = [
          '.json',
          '.gpx',
          '.kml',
          '.fit',
          '.geojson',
          '.csv'
        ];
        final locationFiles = droppedFiles.where((f) {
          final ext = path.extension(f.path).toLowerCase();
          return locationExtensions.contains(ext);
        }).toList();

        final photoFiles = droppedFiles.where((f) {
          final ext = path.extension(f.path).toLowerCase();
          return !locationExtensions.contains(ext);
        }).toList();

        if (locationFiles.isNotEmpty) {
          await _handleImportedLocationFiles(
              context, appState, settings, locationFiles);
        }

        if (photoFiles.isNotEmpty) {
          _loadPhotosFromFiles(photoFiles);
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            AbsorbPointer(
              absorbing: _isWritingExif,
              child: Row(
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
                                        const Icon(Icons.satellite_alt,
                                            size: 18),
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
                                    await appState
                                        .saveEditingChanges(timeOffset);
                                    setState(() => _selectedPointIndex = null);
                                    _loadPointsForSelectedDate();
                                    if (context.mounted) {
                                      _MacToastMessenger.of(context)
                                          .showSnackBar(
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

            // Top-Right Controls: Shift Edit Toggle & Saving Indicator
            Positioned(
              top: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isWritingExif) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.3),
                          width: 1,
                        ),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 8,
                              offset: Offset(0, 3))
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Theme.of(context).colorScheme.primary,
                              value: _exifTotal > 0
                                  ? _exifProcessed / _exifTotal
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Writing EXIF: $_exifProcessed / $_exifTotal',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Shift Edit Toggle Button
                  Tooltip(
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
                                    : Theme.of(context).colorScheme.onSurface,
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
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Undo 1 Step Button (Appears when there are edits in history stack)
                  if (_editHistoryStack.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Tooltip(
                      message:
                          'Undo 1 edit step (${_editHistoryStack.length} step(s) available)',
                      child: Material(
                        color: Colors.amber.shade700,
                        borderRadius: BorderRadius.circular(20),
                        elevation: 3,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            final tz = settings.geotagTimezone.toDouble();
                            _performUndoStep(appState, currentDateInfo, tz);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.undo,
                                    size: 15, color: Colors.white),
                                const SizedBox(width: 6),
                                Text(
                                  'Undo 1 Step (${_editHistoryStack.length})',
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
                    ),
                  ],

                  // Saving Indicator (Appears directly below Shift Edit when saving)
                  if (_isSaving) ...[
                    const SizedBox(height: 8),
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _isSaving ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 6,
                                  offset: Offset(0, 2))
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Saving...',
                                style: TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // macOS Style Stacked Notifications
            if (_macNotifications.isNotEmpty)
              Positioned(
                top: 16,
                right: 16,
                child: SizedBox(
                  width: 320,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: _macNotifications.map((n) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: n.backgroundColor.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.12),
                              width: 1,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black38,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              )
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.info_outline,
                                      size: 16, color: Colors.white),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      n.message,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        _macNotifications.removeWhere(
                                            (item) => item.id == n.id);
                                      });
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(2.0),
                                      child: Icon(Icons.close,
                                          size: 14, color: Colors.white70),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
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
                if (_selectedPhotoSet.length > 1) ...[
                  FilledButton.icon(
                    onPressed: _clusterSelectedPhotos,
                    icon: const Icon(Icons.pin_drop, size: 14),
                    label: Text('Cluster (${_selectedPhotoSet.length})',
                        style: const TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (_hasUnsavedPhotoChanges)
                  FilledButton.icon(
                    onPressed: () async {
                      final photosToSave =
                          _photos.where((p) => p.isGpsModified).toList();
                      if (photosToSave.isEmpty) return;
                      await _writePhotoGpsToExif(photosToSave);
                      if (context.mounted) {
                        _MacToastMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                'Saved EXIF for ${photosToSave.length} photo(s)'),
                            backgroundColor: Colors.green.shade700,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.save, size: 16),
                    label:
                        const Text('Save All', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
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
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                },
              ),
              child: ListView.builder(
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                itemCount: _currentDatePhotos.length,
                itemBuilder: (context, idx) {
                  final photo = _currentDatePhotos[idx];
                  final isSelected = _selectedPhoto == photo ||
                      _selectedPhotoSet.contains(photo);
                  return GestureDetector(
                    onTap: () {
                      _handlePhotoSelection(photo);
                      if (_selectedPhoto == photo && photo.gpsLatLng != null) {
                        _animatedMapMove(
                          photo.gpsLatLng!,
                          _mapController.camera.zoom > 12.0
                              ? _mapController.camera.zoom
                              : 15.0,
                        );
                      } else if (_selectedPhoto == photo &&
                          photo.gpsLatLng == null) {
                        // No GPS: focus sidebar timeline at photo's time
                        WidgetsBinding.instance.addPostFrameCallback(
                            (_) => _focusTimelineForPhoto(photo));
                      }
                    },
                    onSecondaryTapDown: (details) {
                      _showPhotoContextMenu(
                          context, details.globalPosition, photo);
                    },
                    child: Container(
                      width: 80,
                      height: 80,
                      margin: const EdgeInsets.only(right: 8),
                      padding: EdgeInsets.all(isSelected ? 3.5 : (photo.addedToTimeline ? 2.5 : 0)),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : (photo.addedToTimeline
                                ? Colors.green
                                : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.file(
                              photo.file,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              cacheWidth: 150,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey.shade800,
                                child: const Icon(Icons.broken_image,
                                    size: 16, color: Colors.white54),
                              ),
                            ),
                          ),
                          // Red dot badge for missing Lens info (Top-Left)
                          if (!photo.hasLensInfo)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 1.5),
                                ),
                              ),
                            ),
                          // GPS badge
                          if (photo.gpsLatLng != null || photo.isGpsModified)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: photo.isGpsModified
                                      ? Colors.amber.shade800
                                      : (photo.addedToTimeline
                                          ? Colors.green
                                          : Colors.blue),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  photo.isGpsModified
                                      ? Icons.edit
                                      : (photo.addedToTimeline
                                          ? Icons.check
                                          : Icons.gps_fixed),
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
          // Info Column
          Expanded(
            flex: 4,
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
          const SizedBox(width: 12),
          // Vertical Divider
          Container(
            height: 38,
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(width: 12),
          // Metadata Column (Lens, Focal Length, F-Number, Shutter Speed)
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.camera_outlined,
                        size: 13, color: Colors.purpleAccent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        photo.hasLensInfo
                            ? (photo.lensModel ??
                                photo.lensMake ??
                                '${photo.focalLength}mm')
                            : 'Lens: Not Set (${photo.focalLength != null ? "${photo.focalLength!.toStringAsFixed(1).replaceAll('.0', '')}mm" : "0mm"} / f/${photo.fNumber != null ? photo.fNumber!.toStringAsFixed(1).replaceAll('.0', '') : "0"})',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: photo.hasLensInfo
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.redAccent,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.tune, size: 12, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Focal: ${photo.focalLength != null ? "${photo.focalLength!.toStringAsFixed(1).replaceAll('.0', '')}mm" : "0mm"}  •  '
                        'Aperture: ${photo.fNumber != null ? "f/${photo.fNumber!.toStringAsFixed(1).replaceAll('.0', '')}" : "f/0"}  •  '
                        'Speed: ${photo.shutterSpeed ?? "-"}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Colors.grey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Actions
          if (photo.gpsLatLng != null && !photo.addedToTimeline)
            FilledButton.icon(
              onPressed: () async {
                await _addPhotoGpsToTimeline(photo);
                await _writePhotoGpsToExif([photo]);
                if (context.mounted) {
                  _MacToastMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Added to timeline & EXIF saved for "${photo.filename}"'),
                      backgroundColor: Colors.green.shade700,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.save_as, size: 16),
              label: const Text('Save'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.indigo,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
            )
          else if (photo.gpsLatLng == null && photo.interpolatedLatLng != null)
            FilledButton.icon(
              onPressed: () async {
                await _applyInterpolatedGeotag(photo);
                await _writePhotoGpsToExif([photo]);
                if (context.mounted) {
                  _MacToastMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Geotag applied & EXIF saved for "${photo.filename}"'),
                      backgroundColor: Colors.green.shade700,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.save_as, size: 16),
              label: const Text('Save'),
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
          if (photo.assignedLatLng != null) ...[
            IconButton(
              onPressed: () => _animatedMapMove(photo.assignedLatLng!, 16),
              icon: const Icon(Icons.center_focus_strong, size: 18),
              tooltip: 'Navigate to location',
              visualDensity: VisualDensity.compact,
            ),
            OutlinedButton.icon(
              onPressed: () {
                if (Platform.isWindows) {
                  Process.run('start', ['', photo.file.path], runInShell: true);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open', style: TextStyle(fontSize: 12)),
            ),
          ],
          if (_selectedPhotoSet.length > 1) ...[
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _clusterSelectedPhotos,
              icon: const Icon(Icons.pin_drop, size: 16),
              label: const Text('Cluster Selected',
                  style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal.shade700,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ],
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
                      _animatedMapMove(
                        photo.gpsLatLng!,
                        _mapController.camera.zoom > 12.0
                            ? _mapController.camera.zoom
                            : 15.0,
                      );
                    } else {
                      // No GPS: focus sidebar timeline at photo's time
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _focusTimelineForPhoto(photo));
                    }
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(photo.file,
                              fit: BoxFit.cover,
                              cacheWidth: 180,
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
                            color: photo.isGpsModified
                                ? Colors.amber.shade800
                                : (photo.addedToTimeline
                                    ? Colors.green
                                    : (photo.gpsLatLng != null
                                        ? Colors.blue
                                        : Colors.orange)),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            photo.isGpsModified
                                ? Icons.edit
                                : (photo.addedToTimeline
                                    ? Icons.check
                                    : (photo.gpsLatLng != null
                                        ? Icons.gps_fixed
                                        : Icons.gps_off)),
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

  List<LocationPoint> _getPointsForSelectedDay(
      AppStateProvider appState, DateTime selectedDate, double timezoneOffset) {
    if (appState.isEditing) {
      return appState.editingPoints;
    }

    final currentDayInfo = appState.allDates.firstWhere(
      (d) =>
          d.date.year == selectedDate.year &&
          d.date.month == selectedDate.month &&
          d.date.day == selectedDate.day,
      orElse: () => DateInfo(
        date: selectedDate,
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );

    final List<LocationPoint> combined = [];
    final prevDate = selectedDate.subtract(const Duration(days: 1));
    final nextDate = selectedDate.add(const Duration(days: 1));

    for (final date in [prevDate, selectedDate, nextDate]) {
      final info = appState.allDates.firstWhere(
        (d) =>
            d.date.year == date.year &&
            d.date.month == date.month &&
            d.date.day == date.day,
        orElse: () => DateInfo(
          date: date,
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );
      if (info.filePath.isNotEmpty &&
          appState.activePaths.containsKey(info.filePath)) {
        final pts = appState.activePaths[info.filePath];
        if (pts != null) {
          combined.addAll(pts);
        }
      }
    }

    if (combined.isEmpty) {
      return appState.activePaths[currentDayInfo.filePath] ?? [];
    }

    final offsetDuration = Duration(minutes: (timezoneOffset * 60).toInt());
    final dayPoints = combined.where((p) {
      final local = p.timestamp.toUtc().add(offsetDuration);
      return local.year == selectedDate.year &&
          local.month == selectedDate.month &&
          local.day == selectedDate.day;
    }).toList();

    dayPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return dayPoints.isNotEmpty
        ? dayPoints
        : (appState.activePaths[currentDayInfo.filePath] ?? []);
  }

  Future<void> _preloadNeighborDates(
      DateTime currentDate, AppStateProvider appState) async {
    final prevDate = currentDate.subtract(const Duration(days: 1));
    final nextDate = currentDate.add(const Duration(days: 1));

    bool loadedAny = false;
    for (final d in [prevDate, nextDate]) {
      final info = appState.allDates.firstWhere(
        (di) =>
            di.date.year == d.year &&
            di.date.month == d.month &&
            di.date.day == d.day,
        orElse: () => DateInfo(
          date: d,
          pointCount: 0,
          filePath: '',
          distance: 0.0,
          state: 'original',
          source: 'merge',
          hasTimelineBackup: false,
          hasGpxBackup: false,
        ),
      );
      if (info.filePath.isNotEmpty) {
        if (!appState.activePaths.containsKey(info.filePath) ||
            appState.activePaths[info.filePath]!.isEmpty) {
          final pts = await LocationManager.loadLocationFile(info.filePath);
          appState.activePaths[info.filePath] = pts;
          loadedAny = true;
        }
      }
    }
    if (loadedAny && mounted) {
      setState(() {});
    }
  }

  TimelinePlace? _getPreviousDayLastStayPlace(
      AppStateProvider appState, DateTime currentDate, double offset) {
    final prevDate = currentDate.subtract(const Duration(days: 1));
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
    if (prevDateInfo.filePath.isEmpty) return null;
    final prevPoints = appState.activePaths[prevDateInfo.filePath];
    if (prevPoints == null || prevPoints.isEmpty) return null;

    final prevRawItems = _clusterTimelineRaw(prevPoints, offset);
    if (prevRawItems.isEmpty) return null;

    final lastItem = prevRawItems.last;
    if (lastItem is TimelinePlace) {
      return lastItem;
    }
    return null;
  }

  DateTime? _getNextDayFirstMoveTime(AppStateProvider appState,
      DateTime currentDate, double offset, LatLng currentCenter) {
    final nextDate = currentDate.add(const Duration(days: 1));
    final nextDateInfo = appState.allDates.firstWhere(
      (d) =>
          d.date.year == nextDate.year &&
          d.date.month == nextDate.month &&
          d.date.day == nextDate.day,
      orElse: () => DateInfo(
        date: nextDate,
        pointCount: 0,
        filePath: '',
        distance: 0.0,
        state: 'original',
        source: 'merge',
        hasTimelineBackup: false,
        hasGpxBackup: false,
      ),
    );
    if (nextDateInfo.filePath.isEmpty) return null;
    final nextPoints = appState.activePaths[nextDateInfo.filePath];
    if (nextPoints == null || nextPoints.isEmpty) return null;

    final nextRawItems = _clusterTimelineRaw(nextPoints, offset);
    if (nextRawItems.isEmpty) return null;

    final firstItem = nextRawItems.first;
    if (firstItem is TimelinePlace) {
      final dist = GeoUtils.distanceBetween(firstItem.center, currentCenter);
      if (dist < TimelineConstants.stayPointDistanceThreshold) {
        return firstItem.endTime;
      }
    } else if (firstItem is TimelinePath && firstItem.points.isNotEmpty) {
      final dist = GeoUtils.distanceBetween(
          firstItem.points.first.latLng, currentCenter);
      if (dist < TimelineConstants.stayPointDistanceThreshold) {
        return firstItem.startTime;
      }
    }
    return null;
  }

  List<TimelineItem> _clusterTimeline(
      List<LocationPoint> points, double timezoneOffset) {
    final List<TimelineItem> rawItems =
        _clusterTimelineRaw(points, timezoneOffset);

    final appState = context.read<AppStateProvider>();
    if (_selectedDate != null) {
      _preloadNeighborDates(_selectedDate!, appState);
      final currentDayMidnight = DateTime.utc(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        0,
        0,
        0,
      ).subtract(Duration(minutes: (timezoneOffset * 60).toInt()));

      final prevStayPlace = _getPreviousDayLastStayPlace(
          appState, _selectedDate!, timezoneOffset);

      if (rawItems.isNotEmpty) {
        final firstItem = rawItems.first;
        final firstLocation = firstItem is TimelinePlace
            ? firstItem.center
            : (firstItem as TimelinePath).points.first.latLng;

        final stayCenter = prevStayPlace != null
            ? (GeoUtils.distanceBetween(prevStayPlace.center, firstLocation) <
                    TimelineConstants.stayPointDistanceThreshold
                ? prevStayPlace.center
                : firstLocation)
            : firstLocation;

        final stayStartTime = prevStayPlace != null
            ? (GeoUtils.distanceBetween(prevStayPlace.center, firstLocation) <
                    TimelineConstants.stayPointDistanceThreshold
                ? prevStayPlace.startTime
                : currentDayMidnight)
            : currentDayMidnight;

        if (prevStayPlace != null &&
            firstItem is TimelinePlace &&
            GeoUtils.distanceBetween(prevStayPlace.center, firstItem.center) <
                TimelineConstants.stayPointDistanceThreshold) {
          final newPlace = TimelinePlace(
            points: [...prevStayPlace.points, ...firstItem.points],
            startTime: prevStayPlace.startTime,
            endTime: firstItem.endTime,
            center: firstItem.center,
          );
          newPlace.geotaggedPhotos = firstItem.geotaggedPhotos;
          newPlace.ungeotaggedPhotos = firstItem.ungeotaggedPhotos;
          rawItems[0] = newPlace;
        } else if (firstItem.startTime.isAfter(currentDayMidnight) &&
            firstItem.startTime.difference(currentDayMidnight).inMinutes > 1) {
          final stayPoints = [
            LocationPoint(
              latitude: stayCenter.latitude,
              longitude: stayCenter.longitude,
              timestamp: stayStartTime,
            ),
            LocationPoint(
              latitude: stayCenter.latitude,
              longitude: stayCenter.longitude,
              timestamp: firstItem.startTime,
            ),
          ];

          final initialStay = TimelinePlace(
            points: stayPoints,
            startTime: stayStartTime,
            endTime: firstItem.startTime,
            center: stayCenter,
          );

          rawItems.insert(0, initialStay);
        }
      } else if (prevStayPlace != null) {
        final currentDayEnd = currentDayMidnight.add(const Duration(hours: 24));
        final stayPoints = [
          LocationPoint(
            latitude: prevStayPlace.center.latitude,
            longitude: prevStayPlace.center.longitude,
            timestamp: prevStayPlace.startTime,
          ),
          LocationPoint(
            latitude: prevStayPlace.center.latitude,
            longitude: prevStayPlace.center.longitude,
            timestamp: currentDayEnd,
          ),
        ];

        final initialStay = TimelinePlace(
          points: stayPoints,
          startTime: prevStayPlace.startTime,
          endTime: currentDayEnd,
          center: prevStayPlace.center,
        );

        rawItems.add(initialStay);
      }

      // Check if last item of today extends into next day
      if (rawItems.isNotEmpty && rawItems.last is TimelinePlace) {
        final lastPlace = rawItems.last as TimelinePlace;
        final nextDayEndTime = _getNextDayFirstMoveTime(
            appState, _selectedDate!, timezoneOffset, lastPlace.center);
        if (nextDayEndTime != null &&
            nextDayEndTime.isAfter(lastPlace.endTime)) {
          final newPlace = TimelinePlace(
            points: lastPlace.points,
            startTime: lastPlace.startTime,
            endTime: nextDayEndTime,
            center: lastPlace.center,
          );
          newPlace.geotaggedPhotos = lastPlace.geotaggedPhotos;
          newPlace.ungeotaggedPhotos = lastPlace.ungeotaggedPhotos;
          rawItems[rawItems.length - 1] = newPlace;
        }
      }
    }

    // Post-processing: Automatically merge adjacent TimelinePlace items if at same location (< 70m)
    final double distThreshold = TimelineConstants.stayPointDistanceThreshold;
    final List<TimelineItem> mergedItems = [];

    for (final item in rawItems) {
      if (mergedItems.isNotEmpty &&
          mergedItems.last is TimelinePlace &&
          item is TimelinePlace) {
        final lastPlace = mergedItems.last as TimelinePlace;
        final dist = GeoUtils.distanceBetween(lastPlace.center, item.center);
        if (dist < distThreshold) {
          final combinedPoints = [
            ...lastPlace.points,
            ...item.points,
          ];
          combinedPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

          double latSum = 0;
          double lngSum = 0;
          for (final p in combinedPoints) {
            latSum += p.latitude;
            lngSum += p.longitude;
          }
          final newCenter = LatLng(
              latSum / combinedPoints.length, lngSum / combinedPoints.length);

          mergedItems[mergedItems.length - 1] = TimelinePlace(
            points: combinedPoints,
            startTime: lastPlace.startTime.isBefore(item.startTime)
                ? lastPlace.startTime
                : item.startTime,
            endTime: lastPlace.endTime.isAfter(item.endTime)
                ? lastPlace.endTime
                : item.endTime,
            center: newCenter,
          );
          continue;
        }
      }
      mergedItems.add(item);
    }

    // Connect adjacent TimelinePlace items at different locations with a TimelinePath
    final List<TimelineItem> finalItems = [];
    for (int k = 0; k < mergedItems.length; k++) {
      final item = mergedItems[k];
      finalItems.add(item);
      if (k < mergedItems.length - 1 &&
          item is TimelinePlace &&
          mergedItems[k + 1] is TimelinePlace) {
        final nextPlace = mergedItems[k + 1] as TimelinePlace;
        final dist = GeoUtils.distanceBetween(item.center, nextPlace.center);
        final timeGapSec =
            nextPlace.startTime.difference(item.endTime).inSeconds;
        if (timeGapSec >= 10 || dist >= 5.0) {
          final connectingPoints = [
            LocationPoint(
              latitude: item.center.latitude,
              longitude: item.center.longitude,
              timestamp: item.endTime,
            ),
            LocationPoint(
              latitude: nextPlace.center.latitude,
              longitude: nextPlace.center.longitude,
              timestamp: nextPlace.startTime,
            ),
          ];
          finalItems.add(TimelinePath(
            points: connectingPoints,
            startTime: item.endTime,
            endTime: nextPlace.startTime,
            distance: dist,
          ));
        }
      }
    }

    return finalItems;
  }

  void _openAddPlaceSeparationDialog(
    BuildContext context,
    TimelinePath item,
    AppStateProvider appState,
    DateInfo dateInfo,
  ) {
    final settings = context.read<SettingsProvider>();
    final offset = settings.geotagTimezone.toDouble();

    double centerLat = 0;
    double centerLng = 0;
    if (item.points.isNotEmpty) {
      centerLat = item.points.fold<double>(0, (sum, p) => sum + p.latitude) /
          item.points.length;
      centerLng = item.points.fold<double>(0, (sum, p) => sum + p.longitude) /
          item.points.length;
    }

    final latCtrl = TextEditingController(text: centerLat.toStringAsFixed(6));
    final lngCtrl = TextEditingController(text: centerLng.toStringAsFixed(6));

    final midIndex =
        (item.points.length / 2).floor().clamp(0, item.points.length - 1);
    final midTimeUtc = item.points.isNotEmpty
        ? item.points[midIndex].timestamp
        : item.startTime;
    final defaultArrivalLocal =
        midTimeUtc.toUtc().add(Duration(minutes: (offset * 60).toInt()));
    final defaultDepartureLocal =
        defaultArrivalLocal.add(const Duration(minutes: 15));

    TimeOfDay arrivalTime = TimeOfDay(
      hour: defaultArrivalLocal.hour,
      minute: defaultArrivalLocal.minute,
    );
    TimeOfDay departureTime = TimeOfDay(
      hour: defaultDepartureLocal.hour,
      minute: defaultDepartureLocal.minute,
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final arrivalStr =
              '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';
          final departureStr =
              '${departureTime.hour.toString().padLeft(2, '0')}:${departureTime.minute.toString().padLeft(2, '0')}';

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.add_location_alt, color: Colors.deepOrange),
                SizedBox(width: 8),
                Text('Add Place (Separation)'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Insert a place (stay point) into this road to separate it into 2 paths.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: latCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Latitude',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: lngCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Longitude',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 14),
                  const Text('Arrival Time (Thời gian đến):',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () async {
                      final tod = await showTimePicker(
                        context: context,
                        initialTime: arrivalTime,
                      );
                      if (tod != null) {
                        setDialogState(() {
                          arrivalTime = tod;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.access_time,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            arrivalStr,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const Spacer(),
                          const Text('Change',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.blue)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text('Departure Time (Thời gian đi):',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () async {
                      final tod = await showTimePicker(
                        context: context,
                        initialTime: departureTime,
                      );
                      if (tod != null) {
                        setDialogState(() {
                          departureTime = tod;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.access_time_filled,
                              size: 16,
                              color: Theme.of(context).colorScheme.secondary),
                          const SizedBox(width: 8),
                          Text(
                            departureStr,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                          const Spacer(),
                          const Text('Change',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.blue)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.add_location_alt, size: 16),
                label: const Text('Add Place'),
                onPressed: () async {
                  final lat = double.tryParse(latCtrl.text);
                  final lng = double.tryParse(lngCtrl.text);
                  if (lat == null || lng == null) return;

                  final localArr = DateTime(
                    dateInfo.date.year,
                    dateInfo.date.month,
                    dateInfo.date.day,
                    arrivalTime.hour,
                    arrivalTime.minute,
                    0,
                  );
                  final localDep = DateTime(
                    dateInfo.date.year,
                    dateInfo.date.month,
                    dateInfo.date.day,
                    departureTime.hour,
                    departureTime.minute,
                    0,
                  );

                  if (localDep.isBefore(localArr)) {
                    _MacToastMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Departure time must be after arrival time!'),
                      ),
                    );
                    return;
                  }

                  final utcArr = localArr
                      .subtract(Duration(minutes: (offset * 60).toInt()))
                      .toUtc();
                  final utcDep = localDep
                      .subtract(Duration(minutes: (offset * 60).toInt()))
                      .toUtc();

                  final pArr = LocationPoint(
                    latitude: lat,
                    longitude: lng,
                    timestamp: utcArr,
                  );
                  final pDep = LocationPoint(
                    latitude: lat,
                    longitude: lng,
                    timestamp: utcDep,
                  );

                  final allDayPoints = List<LocationPoint>.from(
                      appState.activePaths[dateInfo.filePath] ?? []);
                  _pushUndoState(allDayPoints);

                  allDayPoints.addAll([pArr, pDep]);
                  allDayPoints
                      .sort((a, b) => a.timestamp.compareTo(b.timestamp));

                  await appState.saveListPoints(dateInfo, allDayPoints);
                  _loadPointsForSelectedDate();

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    _MacToastMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            'Added place separation ($arrivalStr - $departureStr)'),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showTimelineItemContextMenu(
      BuildContext context,
      Offset globalPosition,
      TimelineItem item,
      int index,
      List<TimelineItem> allItems) async {
    if (_ignoreNextPlaceContextMenu) {
      _ignoreNextPlaceContextMenu = false;
      return;
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final relativeRect = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    final appState = context.read<AppStateProvider>();
    final dateInfo = _currentDateInfo(appState);

    List<PopupMenuEntry<String>> menuItems = [];

    final itemPhotos = (item is TimelinePlace)
        ? [...item.geotaggedPhotos, ...item.ungeotaggedPhotos]
        : (item is TimelinePath
            ? [...item.geotaggedPhotos, ...item.ungeotaggedPhotos]
            : <PhotoEntry>[]);
    final photoLabel = item is TimelinePlace ? 'Place' : 'Road Segment';

    if (item is TimelinePlace) {
      menuItems = [
        PopupMenuItem(
          value: 'select_all_images',
          enabled: itemPhotos.isNotEmpty,
          child: Row(
            children: [
              const Icon(Icons.select_all, size: 18, color: Colors.amber),
              const SizedBox(width: 8),
              Text('Select All Images of this $photoLabel (${itemPhotos.length})'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete_place',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Delete Place (Merge Paths)'),
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
    } else if (item is TimelinePath) {
      final hasBackup = _unsnappedSegmentBackups
          .containsKey(_getSegmentKey(item.startTime, item.endTime));

      menuItems = [
        const PopupMenuItem(
          value: 'add_place',
          child: Row(
            children: [
              Icon(Icons.add_location_alt, size: 18, color: Colors.deepOrange),
              SizedBox(width: 8),
              Text('Add Place (Separation)'),
            ],
          ),
        ),
        if (hasBackup)
          const PopupMenuItem(
            value: 'undo_snap',
            child: Row(
              children: [
                Icon(Icons.undo, size: 18, color: Colors.blue),
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
          value: 'add_favorite',
          child: Row(
            children: [
              Icon(Icons.star_border, size: 18, color: Colors.amber),
              SizedBox(width: 8),
              Text('Add to Favorite Roads'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'snap_favorite',
          child: Row(
            children: [
              Icon(Icons.star, size: 18, color: Colors.amber),
              SizedBox(width: 8),
              Text('Snap to Favorite Road...'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'restore_original',
          child: Row(
            children: [
              Icon(Icons.restore, size: 18, color: Colors.orange),
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
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'select_all_images',
          enabled: itemPhotos.isNotEmpty,
          child: Row(
            children: [
              const Icon(Icons.select_all, size: 18, color: Colors.amber),
              const SizedBox(width: 8),
              Text('Select All Images of this $photoLabel (${itemPhotos.length})'),
            ],
          ),
        ),
      ];
    }

    final selected = await showFadeMenu<String>(
      context: context,
      position: relativeRect,
      items: menuItems,
    );

    if (selected != null && context.mounted) {
      _handleTimelineMenuSelection(
          context, selected, item, index, allItems, appState, dateInfo);
    }
  }

  Future<void> _deletePlaceAndMergePaths(
    BuildContext context,
    TimelinePlace item,
    AppStateProvider appState,
    DateInfo dateInfo,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Place'),
        content: const Text(
          'Delete this place (stay point)? The paths before and after will merge into a single continuous road segment.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete & Merge'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    final allDayPoints =
        List<LocationPoint>.from(appState.activePaths[dateInfo.filePath] ?? []);
    _pushUndoState(allDayPoints);

    final placePointTimestamps =
        item.points.map((p) => p.timestamp.millisecondsSinceEpoch).toSet();

    allDayPoints.removeWhere((p) =>
        placePointTimestamps.contains(p.timestamp.millisecondsSinceEpoch));

    allDayPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    await appState.saveListPoints(dateInfo, allDayPoints);
    _loadPointsForSelectedDate();

    if (context.mounted) {
      _MacToastMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deleted place and merged connecting paths.'),
        ),
      );
    }
  }

  void _handleTimelineMenuSelection(
      BuildContext context,
      String value,
      TimelineItem item,
      int index,
      List<TimelineItem> allItems,
      AppStateProvider appState,
      DateInfo dateInfo) async {
    if (value == 'select_all_images') {
      _selectAllPhotosInItem(item);
    } else if (value == 'delete_place' && item is TimelinePlace) {
      _deletePlaceAndMergePaths(context, item, appState, dateInfo);
    } else if (value == 'add_place' && item is TimelinePath) {
      _openAddPlaceSeparationDialog(context, item, appState, dateInfo);
    } else if (value == 'undo_snap' && item is TimelinePath) {
      _undoSnapSegment(item, appState, dateInfo);
    } else if (value == 'snap_osrm' && item is TimelinePath) {
      final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
      _snapSegmentToRoads(context, appState, dateInfo, dayPoints, item, null);
    } else if (value == 'add_favorite' && item is TimelinePath) {
      _addSegmentToFavorites(context, item);
    } else if (value == 'snap_favorite' && item is TimelinePath) {
      _showSnapToFavoriteDialog(context, item);
    } else if (value == 'restore_original' && item is TimelinePath) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore Segment to Original'),
          content: const Text(
            'Restore ONLY this road segment to its original raw backup state? All other roads for this day will remain untouched.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore Segment'),
            ),
          ],
        ),
      );

      if (confirm == true && context.mounted) {
        _restoreSegmentToOriginal(item, appState, dateInfo);
      }
    } else if (value == 'copy_json') {
      _copySegmentJson(context, item);
    } else if (value == 'copy_json_neighbors') {
      _copyJsonWithNeighbors(context, allItems, index);
    }
  }

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
        onSecondaryTapDown: (details) {
          _showTimelineItemContextMenu(
              context, details.globalPosition, item, index, allItems);
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
                                  // Place name badge (tap → dropdown search)
                                  _PlaceNameBadge(
                                    lat: item.center.latitude,
                                    lng: item.center.longitude,
                                    pointsCount: item.points.length,
                                    cachedName: _geocodeCache[
                                        '${item.center.latitude.toStringAsFixed(4)},${item.center.longitude.toStringAsFixed(4)}'],
                                    onAutoLookup: () {
                                      final key =
                                          '${item.center.latitude.toStringAsFixed(4)},${item.center.longitude.toStringAsFixed(4)}';
                                      if (!_geocodingInProgress.contains(key)) {
                                        _geocodingInProgress.add(key);
                                        NominatimService.instance
                                            .reverseLookup(item.center.latitude,
                                                item.center.longitude)
                                            .then((name) {
                                          if (mounted) {
                                            setState(() {
                                              _geocodeCache[key] = name;
                                              _geocodingInProgress.remove(key);
                                            });
                                          }
                                        });
                                      }
                                    },
                                    onNameSelected: (name) {
                                      final key =
                                          '${item.center.latitude.toStringAsFixed(4)},${item.center.longitude.toStringAsFixed(4)}';
                                      setState(() {
                                        _geocodeCache[key] = name;
                                      });
                                      NominatimService.instance.setCustomName(
                                          item.center.latitude,
                                          item.center.longitude,
                                          name);
                                    },
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
                                          final startLocal = item.startTime
                                              .toUtc()
                                              .add(Duration(
                                                  minutes: (timezoneOffset * 60)
                                                      .toInt()));
                                          final tod = await showTimePicker(
                                            context: context,
                                            initialTime: TimeOfDay(
                                              hour: startLocal.hour,
                                              minute: startLocal.minute,
                                            ),
                                          );
                                          if (tod != null) {
                                            final newStartLocal = DateTime.utc(
                                              startLocal.year,
                                              startLocal.month,
                                              startLocal.day,
                                              tod.hour,
                                              tod.minute,
                                              startLocal.second,
                                            );
                                            final newStartUtc =
                                                newStartLocal.subtract(Duration(
                                                    minutes:
                                                        (timezoneOffset * 60)
                                                            .toInt()));
                                            _updatePlaceTimeBounds(
                                              item,
                                              newStartUtc,
                                              item.endTime.toUtc(),
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
                                                _MacToastMessenger.of(context)
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
                          _buildTimelinePhotoRows(context, item, index, allItems),
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
        onSecondaryTapDown: (details) {
          _showTimelineItemContextMenu(
              context, details.globalPosition, item, index, allItems);
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
                                    value: 'add_favorite',
                                    child: Row(
                                      children: [
                                        Icon(Icons.star_border,
                                            size: 18, color: Colors.amber),
                                        SizedBox(width: 8),
                                        Text('Add to Favorite Roads'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'snap_favorite',
                                    child: Row(
                                      children: [
                                        Icon(Icons.star,
                                            size: 18, color: Colors.amber),
                                        SizedBox(width: 8),
                                        Text('Snap to Favorite Road...'),
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
                              onSelected: (val) {
                                final appState =
                                    context.read<AppStateProvider>();
                                final dateInfo = _currentDateInfo(appState);
                                _handleTimelineMenuSelection(context, val, item,
                                    index, allItems, appState, dateInfo);
                              },
                            ),
                          ],
                        ),
                        if (item.geotaggedPhotos.isNotEmpty ||
                            item.ungeotaggedPhotos.isNotEmpty)
                          _buildTimelinePhotoRows(context, item, index, allItems),
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

  void _interpolatePointsRange(List<LocationPoint> points, int start, int end) {
    if (end - start <= 1) return;

    final pStart = points[start];
    final pEnd = points[end];
    final timeStart = pStart.timestamp;
    final timeEnd = pEnd.timestamp;
    final totalDuration = timeEnd.difference(timeStart);

    final List<double> distances = [0.0];
    double totalDist = 0.0;
    for (int i = start; i < end; i++) {
      final d =
          GeoUtils.distanceBetween(points[i].latLng, points[i + 1].latLng);
      totalDist += d;
      distances.add(totalDist);
    }

    for (int i = start + 1; i < end; i++) {
      final oldPt = points[i];
      final double progress = totalDist > 0
          ? distances[i - start] / totalDist
          : (i - start) / (end - start);

      final int offsetMs = (totalDuration.inMilliseconds * progress).toInt();
      final newTime = timeStart.add(Duration(milliseconds: offsetMs));

      points[i] = LocationPoint(
        latitude: oldPt.latitude,
        longitude: oldPt.longitude,
        timestamp: newTime,
        elevation: oldPt.elevation,
        activityType: oldPt.activityType,
      );
    }
  }

  LocationPoint _findNearestOldPoint(
      LocationPoint newPt, List<LocationPoint> originalPoints) {
    LocationPoint nearest = originalPoints.first;
    double minDist = double.infinity;
    for (final oldPt in originalPoints) {
      final dist = GeoUtils.distanceBetween(newPt.latLng, oldPt.latLng);
      if (dist < minDist) {
        minDist = dist;
        nearest = oldPt;
      }
    }
    return nearest;
  }

  String _getSegmentKey(DateTime start, DateTime end) =>
      '${start.millisecondsSinceEpoch}_${end.millisecondsSinceEpoch}';

  Future<void> _snapSegmentToRoads(
      BuildContext context,
      AppStateProvider appState,
      DateInfo dateInfo,
      List<LocationPoint> dayPoints,
      TimelinePath segment,
      LatLng? draggedLatLng,
      {bool forceEvenTimeDistribution = false}) async {
    if (segment.points.isEmpty) return;

    final segmentKey = _getSegmentKey(segment.startTime, segment.endTime);
    _unsnappedSegmentBackups[segmentKey] =
        List<LocationPoint>.from(segment.points);

    final settings = context.read<SettingsProvider>();
    final useGoogle = settings.routingProvider == 'google';
    final googleApiKey = settings.googleMapsApiKey;

    if (useGoogle && googleApiKey.isEmpty) {
      _MacToastMessenger.of(context).showSnackBar(
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
                (data['matchings'] as List).length == 1) {
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
              final routeBody = await routeRes.transform(utf8.decoder).join();
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

    if (newPoints.isNotEmpty) {
      if (forceEvenTimeDistribution) {
        if (draggedLatLng != null) {
          // Find the dragged point index in newPoints
          int draggedIdxInNew = 0;
          double minD = double.infinity;
          for (int i = 0; i < newPoints.length; i++) {
            final d =
                GeoUtils.distanceBetween(newPoints[i].latLng, draggedLatLng);
            if (d < minD) {
              minD = d;
              draggedIdxInNew = i;
            }
          }

          // Find anchorStart (closest preceding point near its original position)
          int anchorStart = 0;
          for (int k = draggedIdxInNew; k >= 0; k--) {
            final nearestOld =
                _findNearestOldPoint(newPoints[k], originalPoints);
            final dist = GeoUtils.distanceBetween(
                newPoints[k].latLng, nearestOld.latLng);
            if (dist < 15.0) {
              anchorStart = k;
              break;
            }
          }

          // Find anchorEnd (closest succeeding point near its original position)
          int anchorEnd = newPoints.length - 1;
          for (int m = draggedIdxInNew; m < newPoints.length; m++) {
            final nearestOld =
                _findNearestOldPoint(newPoints[m], originalPoints);
            final dist = GeoUtils.distanceBetween(
                newPoints[m].latLng, nearestOld.latLng);
            if (dist < 15.0) {
              anchorEnd = m;
              break;
            }
          }

          // Assign original timestamps to points outside the affected range
          for (int i = 0; i <= anchorStart; i++) {
            final nearestOld =
                _findNearestOldPoint(newPoints[i], originalPoints);
            newPoints[i] = LocationPoint(
              latitude: newPoints[i].latitude,
              longitude: newPoints[i].longitude,
              timestamp: nearestOld.timestamp,
              elevation: nearestOld.elevation,
              activityType: nearestOld.activityType,
            );
          }
          for (int i = anchorEnd; i < newPoints.length; i++) {
            final nearestOld =
                _findNearestOldPoint(newPoints[i], originalPoints);
            newPoints[i] = LocationPoint(
              latitude: newPoints[i].latitude,
              longitude: newPoints[i].longitude,
              timestamp: nearestOld.timestamp,
              elevation: nearestOld.elevation,
              activityType: nearestOld.activityType,
            );
          }

          // Interpolate timestamps inside the affected range
          if (anchorEnd > anchorStart + 1) {
            _interpolatePointsRange(newPoints, anchorStart, anchorEnd);
          }
        } else {
          // If no draggedLatLng is provided, interpolate the entire segment
          _interpolatePointsRange(newPoints, 0, newPoints.length - 1);
        }
      } else {
        // Without Shift: Lock all points to their closest original timestamps
        for (int i = 0; i < newPoints.length; i++) {
          final nearestOld = _findNearestOldPoint(newPoints[i], originalPoints);
          newPoints[i] = LocationPoint(
            latitude: newPoints[i].latitude,
            longitude: newPoints[i].longitude,
            timestamp: nearestOld.timestamp,
            elevation: nearestOld.elevation,
            activityType: nearestOld.activityType,
          );
        }
      }
    }

    if (newPoints.isEmpty) {
      if (context.mounted) {
        _MacToastMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Failed to route segment using ${useGoogle ? 'Google Roads API' : 'OSRM'}.')),
        );
      }
      return;
    }

    _pushUndoState(dayPoints);
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
      _MacToastMessenger.of(context).showSnackBar(
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
        _MacToastMessenger.of(context).showSnackBar(
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
          _MacToastMessenger.of(context).showSnackBar(
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
        _MacToastMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Road segment restored to original raw state.')),
        );
      }
    } catch (e) {
      if (mounted) {
        _MacToastMessenger.of(context).showSnackBar(
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
    final origStart = place.startTime.toUtc();
    final origEnd = place.endTime.toUtc();
    var newStartUtc = newStart.toUtc();
    var newEndUtc = newEnd.toUtc();

    final settings = context.read<SettingsProvider>();
    final timelineItems =
        _clusterTimeline(dayPoints, settings.geotagTimezone.toDouble());
    final placeIdx =
        timelineItems.indexWhere((t) => t is TimelinePlace && t == place);

    TimelinePath? prevPath;
    TimelinePath? nextPath;

    if (placeIdx != -1) {
      if (placeIdx - 1 >= 0 && timelineItems[placeIdx - 1] is TimelinePath) {
        prevPath = timelineItems[placeIdx - 1] as TimelinePath;
        final key = _getSegmentKey(prevPath.startTime, prevPath.endTime);
        _unsnappedSegmentBackups.putIfAbsent(
            key, () => List<LocationPoint>.from(prevPath!.points));
      }
      if (placeIdx + 1 < timelineItems.length &&
          timelineItems[placeIdx + 1] is TimelinePath) {
        nextPath = timelineItems[placeIdx + 1] as TimelinePath;
        final key = _getSegmentKey(nextPath.startTime, nextPath.endTime);
        _unsnappedSegmentBackups.putIfAbsent(
            key, () => List<LocationPoint>.from(nextPath!.points));
      }
    }

    // 1. Constrain bounds within adjacent path segment start/end
    if (prevPath != null) {
      if (newStartUtc.isBefore(prevPath.startTime.toUtc())) {
        newStartUtc = prevPath.startTime.toUtc();
      }
    }
    if (nextPath != null) {
      if (newEndUtc.isAfter(nextPath.endTime.toUtc())) {
        newEndUtc = nextPath.endTime.toUtc();
      }
    }

    if (newEndUtc.difference(newStartUtc) < const Duration(minutes: 1)) {
      newEndUtc = newStartUtc.add(const Duration(minutes: 1));
    }

    _pushUndoState(dayPoints);

    // 2. If newStartUtc reaches or precedes prevPath.startTime, delete prevPath points
    if (prevPath != null && !newStartUtc.isAfter(prevPath.startTime.toUtc())) {
      final prevPointTimestamps = prevPath.points
          .map((p) => p.timestamp.millisecondsSinceEpoch)
          .toSet();
      final placeTimestamps =
          placePts.map((p) => p.timestamp.millisecondsSinceEpoch).toSet();
      updated.removeWhere((p) =>
          prevPointTimestamps.contains(p.timestamp.millisecondsSinceEpoch) &&
          !placeTimestamps.contains(p.timestamp.millisecondsSinceEpoch));
    } else if (prevPath != null && newStartUtc.isBefore(origStart)) {
      updated.removeWhere((p) =>
          prevPath!.points.contains(p) &&
          !p.timestamp.toUtc().isBefore(newStartUtc));
    }

    // 3. If newEndUtc reaches or exceeds nextPath.endTime, delete nextPath points
    if (nextPath != null && !newEndUtc.isBefore(nextPath.endTime.toUtc())) {
      final nextPointTimestamps = nextPath.points
          .map((p) => p.timestamp.millisecondsSinceEpoch)
          .toSet();
      final placeTimestamps =
          placePts.map((p) => p.timestamp.millisecondsSinceEpoch).toSet();
      updated.removeWhere((p) =>
          nextPointTimestamps.contains(p.timestamp.millisecondsSinceEpoch) &&
          !placeTimestamps.contains(p.timestamp.millisecondsSinceEpoch));
    } else if (nextPath != null && newEndUtc.isAfter(origEnd)) {
      updated.removeWhere((p) =>
          nextPath!.points.contains(p) &&
          !p.timestamp.toUtc().isAfter(newEndUtc));
    }

    // 4. Update timestamps for the points of this place
    final totalOldDuration = origEnd.difference(origStart).inMilliseconds;
    final totalNewDuration = newEndUtc.difference(newStartUtc).inMilliseconds;

    for (int i = 0; i < updated.length; i++) {
      final p = updated[i];
      if (placePts.contains(p)) {
        final elapsed =
            p.timestamp.toUtc().difference(origStart).inMilliseconds;
        final ratio = totalOldDuration > 0
            ? (elapsed / totalOldDuration).clamp(0.0, 1.0)
            : 0.0;
        final newTimestamp = newStartUtc
            .add(Duration(milliseconds: (totalNewDuration * ratio).round()))
            .toUtc();
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
      _MacToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Place time range updated to ${DateFormat('HH:mm').format(newStartUtc.toLocal())} – ${DateFormat('HH:mm').format(newEndUtc.toLocal())}'),
        ),
      );
    }
  }

  void _copyToClipboard(
      BuildContext context, String text, String successMessage) {
    Clipboard.setData(ClipboardData(text: text));
    _MacToastMessenger.of(context).showSnackBar(
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
    final messenger = _MacToastMessenger.of(context);
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
  final GestureTapDownCallback? onSecondaryTapDown;

  const _TimelineTileWrapper({
    required this.child,
    required this.isSelected,
    required this.onTap,
    this.onSecondaryTapDown,
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
        onSecondaryTapDown: widget.onSecondaryTapDown,
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
  final bool isDraggingPhoto;
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
    this.isDraggingPhoto = false,
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
                          isDraggingPlace ||
                          isDraggingPhoto)
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

                final isSelected = widget.initialDate.year == date.year &&
                    widget.initialDate.month == date.month &&
                    widget.initialDate.day == date.day;

                final isToday = date.year == DateTime.now().year &&
                    date.month == DateTime.now().month &&
                    date.day == DateTime.now().day;

                Color cellColor = Colors.transparent;
                Color textColor = Theme.of(context).colorScheme.onSurface;

                if (dayInfo != null && dayInfo.filePath.isNotEmpty) {
                  if (dayInfo.state == 'edited' || dayInfo.state == 'snapped') {
                    // Edit rồi -> Màu shade50 (tím nhạt)
                    cellColor = Colors.purple.shade50;
                    textColor = Colors.purple.shade900;
                  } else {
                    // Chưa edit (có timeline data) -> Màu trắng
                    cellColor = Colors.white;
                    textColor = Colors.grey.shade900;
                  }
                } else {
                  // Ko có data -> Trong suốt (trùng màu nền)
                  cellColor = Colors.transparent;
                }

                if (isSelected) {
                  cellColor = Theme.of(context).colorScheme.primary;
                  textColor = Theme.of(context).colorScheme.onPrimary;
                } else if (isToday) {
                  textColor = Theme.of(context).colorScheme.primary;
                }

                Border? cellBorder;
                if (isSelected) {
                  cellBorder = Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2);
                } else if (isToday) {
                  cellBorder = Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 1.5);
                }

                bool hasPhotos = false;
                int missingCount = 0;
                String? missingTooltipMsg;
                if (widget.photos != null && widget.photos!.isNotEmpty) {
                  final photosOnDate = widget.photos!
                      .where((p) =>
                          p.dateTaken != null &&
                          p.dateTaken!.year == date.year &&
                          p.dateTaken!.month == date.month &&
                          p.dateTaken!.day == date.day)
                      .toList();

                  if (photosOnDate.isNotEmpty) {
                    hasPhotos = true;
                    final bool missingGeotag =
                        photosOnDate.any((p) => p.gpsLatLng == null);
                    final bool missingLens =
                        photosOnDate.any((p) => !p.hasLensInfo);

                    if (missingGeotag && missingLens) {
                      missingCount = 2;
                      missingTooltipMsg = 'Thiếu Geotag & thông tin Lens';
                    } else if (missingGeotag) {
                      missingCount = 1;
                      missingTooltipMsg = 'Thiếu toạ độ Geotag';
                    } else if (missingLens) {
                      missingCount = 1;
                      missingTooltipMsg = 'Thiếu thông tin Lens';
                    }
                  }
                }

                Widget cellChild = Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cellColor,
                        borderRadius: BorderRadius.circular(8),
                        border: cellBorder,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            day.toString(),
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.0,
                              fontWeight: isSelected || isToday
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (hasPhotos)
                            Container(
                              width: 4.5,
                              height: 4.5,
                              decoration: BoxDecoration(
                                color:
                                    isSelected ? Colors.white : Colors.purple,
                                shape: BoxShape.circle,
                              ),
                            )
                          else
                            const SizedBox(height: 4.5),
                        ],
                      ),
                    ),
                    if (missingCount > 0)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          width: 14,
                          height: 14,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            missingCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8.5,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                          ),
                        ),
                      ),
                  ],
                );

                if (missingTooltipMsg != null) {
                  cellChild = Tooltip(
                    message: missingTooltipMsg,
                    child: cellChild,
                  );
                }

                return InkWell(
                  onTap: () {
                    Navigator.pop(context, date);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: cellChild,
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
  final String chartMode;
  final Function(String)? onModeChanged;

  const MonthlyDistanceChart({
    super.key,
    required this.selectedDate,
    required this.allDates,
    required this.points,
    required this.timezoneOffset,
    required this.onDateSelected,
    this.chartMode = 'daily',
    this.onModeChanged,
  });

  @override
  State<MonthlyDistanceChart> createState() => _MonthlyDistanceChartState();
}

class _MonthlyDistanceChartState extends State<MonthlyDistanceChart> {
  late String _mode; // 'daily', 'monthly', 'yearly'
  int? _hoveredIndex;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _mode = widget.chartMode;
    _scrollToSelectedDate();
  }

  @override
  void didUpdateWidget(covariant MonthlyDistanceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chartMode != widget.chartMode) {
      _mode = widget.chartMode;
      _scrollToSelectedDate();
    } else if (oldWidget.selectedDate != widget.selectedDate) {
      _scrollToSelectedDate();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelectedDate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      int targetIndex = 0;
      if (_mode == 'daily') {
        targetIndex = widget.selectedDate.day - 1;
      } else if (_mode == 'monthly') {
        targetIndex = widget.selectedDate.month - 1;
      } else {
        targetIndex = 3;
      }
      final double itemWidth =
          _mode == 'daily' ? 38.0 : (_mode == 'monthly' ? 43.0 : 53.0);
      final double targetOffset = (targetIndex * itemWidth) -
          (_scrollController.position.viewportDimension / 2) +
          (itemWidth / 2);
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

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
      labels = List.generate(daysInMonth, (i) {
        final dt = DateTime(
            widget.selectedDate.year, widget.selectedDate.month, i + 1);
        final weekday = DateFormat('E').format(dt);
        final dayNum = (i + 1).toString().padLeft(2, '0');
        return '$weekday\n$dayNum';
      });
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
    String titleText = 'Daily Distance';
    String currentModeTotal = _formatDistance(selectedDateInfo.distance);
    if (_mode == 'monthly') {
      titleText = 'Monthly Distance';
      currentModeTotal = _formatDistance(totalYearDistance);
    } else if (_mode == 'yearly') {
      titleText = 'Yearly Distance';
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '$titleText ($currentModeTotal)',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (selectedDateInfo.filePath.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () async {
                                final appState =
                                    context.read<AppStateProvider>();
                                await appState
                                    .restoreDateToOriginal(selectedDateInfo);
                                if (context.mounted) {
                                  _MacToastMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'Restored ${DateFormat('yyyy-MM-dd').format(selectedDateInfo.date)} to original state.'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }
                                widget.onDateSelected(widget.selectedDate);
                              },
                              child: Tooltip(
                                message: 'Restore to Original Raw Track',
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: selectedDateInfo.state == 'edited' ||
                                            selectedDateInfo.state == 'snapped'
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primaryContainer
                                        : Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: 0.5),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.restart_alt,
                                          size: 13,
                                          color: selectedDateInfo.state ==
                                                      'edited' ||
                                                  selectedDateInfo.state ==
                                                      'snapped'
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant),
                                      const SizedBox(width: 3),
                                      Text(
                                        'Restore',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: selectedDateInfo.state ==
                                                      'edited' ||
                                                  selectedDateInfo.state ==
                                                      'snapped'
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
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
                const SizedBox(width: 8),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _mode,
                    isDense: true,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Daily')),
                      DropdownMenuItem(
                          value: 'monthly', child: Text('Monthly')),
                      DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _mode = val;
                          _hoveredIndex = null;
                        });
                        widget.onModeChanged?.call(val);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 80,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
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
                      behavior: HitTestBehavior.opaque,
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
                            ? 30
                            : (_mode == 'monthly' ? 35 : 45),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: Colors.transparent,
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
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 9,
                                height: 1.1,
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

              final isSelected = widget.selectedDate.year == date.year &&
                  widget.selectedDate.month == date.month &&
                  widget.selectedDate.day == date.day;

              final isToday = date.year == DateTime.now().year &&
                  date.month == DateTime.now().month &&
                  date.day == DateTime.now().day;

              Color cellColor = Colors.transparent;
              Color textColor = Theme.of(context).colorScheme.onSurface;

              if (dayInfo != null && dayInfo.filePath.isNotEmpty) {
                if (dayInfo.state == 'edited' || dayInfo.state == 'snapped') {
                  // Edit rồi -> Màu shade50 (tím nhạt)
                  cellColor = Colors.purple.shade50;
                  textColor = Colors.purple.shade900;
                } else {
                  // Chưa edit (có timeline data) -> Màu trắng
                  cellColor = Colors.white;
                  textColor = Colors.grey.shade900;
                }
              } else {
                // Ko có data -> Trong suốt (trùng màu nền)
                cellColor = Colors.transparent;
              }

              if (isSelected) {
                cellColor = Theme.of(context).colorScheme.primary;
                textColor = Theme.of(context).colorScheme.onPrimary;
              } else if (isToday) {
                textColor = Theme.of(context).colorScheme.primary;
              }

              Border? cellBorder;
              if (isSelected) {
                cellBorder = Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 2);
              } else if (isToday) {
                cellBorder = Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 1.5);
              }

              bool hasPhotos = false;
              int missingCount = 0;
              String? missingTooltipMsg;
              if (widget.photos != null && widget.photos!.isNotEmpty) {
                final photosOnDate = widget.photos!
                    .where((p) =>
                        p.dateTaken != null &&
                        p.dateTaken!.year == date.year &&
                        p.dateTaken!.month == date.month &&
                        p.dateTaken!.day == date.day)
                    .toList();

                if (photosOnDate.isNotEmpty) {
                  hasPhotos = true;
                  final bool missingGeotag =
                      photosOnDate.any((p) => p.gpsLatLng == null);
                  final bool missingLens =
                      photosOnDate.any((p) => !p.hasLensInfo);

                  if (missingGeotag && missingLens) {
                    missingCount = 2;
                    missingTooltipMsg = 'Thiếu Geotag & thông tin Lens';
                  } else if (missingGeotag) {
                    missingCount = 1;
                    missingTooltipMsg = 'Thiếu toạ độ Geotag';
                  } else if (missingLens) {
                    missingCount = 1;
                    missingTooltipMsg = 'Thiếu thông tin Lens';
                  }
                }
              }

              Widget cellChild = Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cellColor,
                      borderRadius: BorderRadius.circular(8),
                      border: cellBorder,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          day.toString(),
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.0,
                            fontWeight: isSelected || isToday
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (hasPhotos)
                          Container(
                            width: 4.5,
                            height: 4.5,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : Colors.purple,
                              shape: BoxShape.circle,
                            ),
                          )
                        else
                          const SizedBox(height: 4.5),
                      ],
                    ),
                  ),
                  if (missingCount > 0)
                    Positioned(
                      top: -3,
                      right: -3,
                      child: Container(
                        width: 14,
                        height: 14,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          missingCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8.5,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                ],
              );

              if (missingTooltipMsg != null) {
                cellChild = Tooltip(
                  message: missingTooltipMsg,
                  child: cellChild,
                );
              }

              return InkWell(
                onTap: () {
                  widget.onDateSelected(date);
                },
                borderRadius: BorderRadius.circular(8),
                child: cellChild,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MacNotification {
  final String id;
  final String message;
  final Color backgroundColor;

  _MacNotification({
    required this.id,
    required this.message,
    required this.backgroundColor,
  });
}

class _MacToastMessenger {
  final BuildContext context;
  _MacToastMessenger(this.context);

  static _MacToastMessenger of(BuildContext context) {
    return _MacToastMessenger(context);
  }

  void showSnackBar(SnackBar snackBar) {
    String text = '';
    if (snackBar.content is Text) {
      text = (snackBar.content as Text).data ?? '';
    } else {
      text = snackBar.content.toString();
    }

    // Tìm state trực tiếp qua context — bền vững hơn static field khi hot reload
    _MapViewerScreenState? state;
    try {
      state = context.findAncestorStateOfType<_MapViewerScreenState>();
    } catch (_) {}

    // Fallback sang static activeState nếu context không tìm được (e.g. async gap)
    final target = state ?? _MapViewerScreenState.activeState;
    if (target != null && target.mounted) {
      target.showMacToast(text, backgroundColor: snackBar.backgroundColor);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION: _PlaceNameBadge — inline expandable place name search
// ═══════════════════════════════════════════════════════════════════════════

/// A badge chip that shows the current place name and, on tap, expands an
/// inline search panel directly below it (no overlay, no lifecycle issues).
class _PlaceNameBadge extends StatefulWidget {
  final double lat;
  final double lng;
  final int pointsCount;
  final String? cachedName;
  final VoidCallback onAutoLookup;
  final ValueChanged<String> onNameSelected;

  const _PlaceNameBadge({
    required this.lat,
    required this.lng,
    required this.pointsCount,
    required this.cachedName,
    required this.onAutoLookup,
    required this.onNameSelected,
  });

  @override
  State<_PlaceNameBadge> createState() => _PlaceNameBadgeState();
}

class _PlaceNameBadgeState extends State<_PlaceNameBadge> {
  bool _isOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<NominatimResult> _results = [];
  bool _isSearching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.cachedName == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onAutoLookup();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _searchCtrl.text = widget.cachedName ?? '';
        _results = [];
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _searchFocus.requestFocus());
      } else {
        _results = [];
        _debounce?.cancel();
      }
    });
  }

  void _onTextChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() => _isSearching = true);
      final results = await NominatimService.instance.search(
        q,
        lat: widget.lat,
        lng: widget.lng,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _isSearching = false;
        });
      }
    });
  }

  void _select(String name) {
    setState(() {
      _isOpen = false;
      _results = [];
      _debounce?.cancel();
    });
    widget.onNameSelected(name);
  }

  @override
  Widget build(BuildContext context) {
    final displayName =
        (widget.cachedName != null && widget.cachedName!.isNotEmpty)
            ? widget.cachedName!
            : 'Place (${widget.pointsCount} pts)';

    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Badge button ────────────────────────────────────────────
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _toggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border:
                  _isOpen ? Border.all(color: cs.primary, width: 1.5) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    displayName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _isOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.arrow_drop_down, size: 18),
                ),
              ],
            ),
          ),
        ),

        // ── Inline search panel (AnimatedSize) ───────────────────
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: _isOpen
              ? Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: 280,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: cs.outline.withValues(alpha: 0.3)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Search TextField
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextField(
                          controller: _searchCtrl,
                          focusNode: _searchFocus,
                          onChanged: _onTextChanged,
                          decoration: InputDecoration(
                            hintText: 'Tìm địa điểm...',
                            hintStyle: const TextStyle(fontSize: 12),
                            prefixIcon: const Icon(Icons.search, size: 16),
                            suffixIcon: _isSearching
                                ? const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ))
                                : (_searchCtrl.text.isNotEmpty
                                    ? IconButton(
                                        iconSize: 14,
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          _searchCtrl.clear();
                                          setState(() => _results = []);
                                        },
                                      )
                                    : null),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6)),
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 6, horizontal: 8),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 12),
                          onSubmitted: (v) {
                            if (v.trim().isNotEmpty) _select(v.trim());
                          },
                        ),
                      ),
                      if (_results.isNotEmpty) const Divider(height: 1),
                      if (_results.isNotEmpty)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final r in _results.take(6))
                              InkWell(
                                onTap: () => _select(r.shortName),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.place,
                                          size: 14, color: Colors.deepOrange),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              r.shortName,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12),
                                            ),
                                            Text(
                                              r.displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: cs.onSurface
                                                      .withValues(alpha: 0.5)),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

