import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/location_point.dart';
import '../providers/app_state_provider.dart';
import '../providers/settings_provider.dart';
import '../services/location_manager.dart';
import '../constants/timeline_constants.dart';
import '../utils/geo_utils.dart';

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

class MapViewerScreen extends StatefulWidget {
  const MapViewerScreen({super.key});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> with TickerProviderStateMixin {
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
  LocationPoint? _previousDayLastStayPoint;

  void _loadPointsForSelectedDate() async {
    setState(() {
      _selectedTimelineItemIndex = null;
    });
    if (_selectedDate == null) return;
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
        final prevPoints = await LocationManager.loadLocationFile(prevDateInfo.filePath);
        if (!mounted) return;
        if (prevPoints.isNotEmpty) {
          final settings = context.read<SettingsProvider>();
          final double timeOffset = settings.geotagTimezone.toDouble();
          final prevItems = _clusterTimelineRaw(prevPoints, timeOffset);
          for (int k = prevItems.length - 1; k >= 0; k--) {
            if (prevItems[k] is StayPointItem) {
              final stay = prevItems[k] as StayPointItem;
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
      appState.setSelectedDatePath(dateInfo, points);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBounds();
      });
    } else {
      appState.setSelectedDatePath(dateInfo, []);
    }
  }

  @override
  void dispose() {
    _mapAnimationController?.dispose();
    super.dispose();
  }

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
      final double lat = startCenter.latitude + (destCenter.latitude - startCenter.latitude) * t;
      final double lng = startCenter.longitude + (destCenter.longitude - startCenter.longitude) * t;
      final double zoom = startZoom + (destZoom - startZoom) * t;

      _mapController.move(LatLng(lat, lng), zoom);
    });

    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        controller.dispose();
        if (_mapAnimationController == controller) {
          _mapAnimationController = null;
        }
      }
    });

    controller.forward();
  }

  void _fitBounds() {
    final appState = context.read<AppStateProvider>();
    final paths = appState.activePaths;
    if (paths.isEmpty) return;

    final allPoints =
        paths.values.expand((points) => points.map((p) => p.latLng)).toList();
    if (allPoints.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(allPoints);

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(50.0),
      ),
    );
  }

  void _handleHover(PointerHoverEvent event, LatLng point) {
    final appState = context.read<AppStateProvider>();
    if (!appState.isEditing) {
      // Non-edit mode: hover over existing tracks
      final paths = appState.activePaths;
      if (paths.isEmpty) return;

      LocationPoint? closestPoint;
      Color? closestColor;
      double minDistance = double.infinity;
      const double snapThreshold = 0.005;

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

      for (final entry in paths.entries) {
        final isSelectedPath = entry.key == currentDayInfo.filePath;
        final color = isSelectedPath ? Colors.purple : Colors.grey;
        for (final p in entry.value) {
          final dLat = p.latitude - point.latitude;
          final dLon = p.longitude - point.longitude;
          final dist = dLat * dLat + dLon * dLon;

          if (dist < minDistance) {
            minDistance = dist;
            closestPoint = p;
            closestColor = color;
          }
        }
      }

      if (minDistance < snapThreshold * snapThreshold) {
        if (_hoveredPoint != closestPoint) {
          setState(() {
            _hoveredPoint = closestPoint;
            _hoveredColor = closestColor;
            _hoveredLatLng = closestPoint?.latLng;
          });
        }
      } else {
        if (_hoveredPoint != null) {
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

  void _handlePointerDown(PointerDownEvent event) {
    final appState = context.read<AppStateProvider>();
    if (!appState.isEditing) return;

    double currentZoom = 13.0;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {}
    final touchThreshold = 0.015 / pow(2, currentZoom - 10);
    final touchThresholdSq = touchThreshold * touchThreshold;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localOffset = renderBox.globalToLocal(event.position);
    final tapLatLng = _mapController.camera.screenOffsetToLatLng(localOffset);

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

  void _handlePointerMove(PointerMoveEvent event) {
    if (_isDraggingPoint && _selectedPointIndex != null) {
      final appState = context.read<AppStateProvider>();
      final RenderBox renderBox = context.findRenderObject() as RenderBox;
      final localOffset = renderBox.globalToLocal(event.position);
      try {
        final newLatLng =
            _mapController.camera.screenOffsetToLatLng(localOffset);
        appState.updatePointCoordinate(_selectedPointIndex!, newLatLng);
      } catch (_) {}
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_isDraggingPoint) {
      setState(() {
        _isDraggingPoint = false;
      });
      _snapAfterDragRelease();
    }
  }

  Future<List<LatLng>> _fetchRouteCoordinates(LatLng start, LatLng end, bool useGoogle, String googleApiKey) async {
    if (useGoogle) {
      final url = 'https://roads.googleapis.com/v1/snapToRoads?path=${start.latitude},${start.longitude}|${end.latitude},${end.longitude}&interpolate=true&key=$googleApiKey';
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
        const SnackBar(content: Text('Please configure your Google Maps API Key in Settings to snap roads.')),
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
      _fetchRouteCoordinates(editingPoints[a].latLng, editingPoints[draggedIdx].latLng, useGoogle, googleApiKey),
      _fetchRouteCoordinates(editingPoints[draggedIdx].latLng, editingPoints[b].latLng, useGoogle, googleApiKey),
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
        final ratio = totalD > 0 ? (dists[k] / totalD) : (k / (route1.length - 1));
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
        final ratio = totalD > 0 ? (dists[k] / totalD) : (k / (route2.length - 1));
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
        final diff = finalPoints[i].timestamp.difference(oldTime).inMilliseconds.abs();
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
      final diff = finalPoints[i].timestamp.difference(oldTime).inMilliseconds.abs();
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
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
                                  DateTime(_selectedDate?.year ?? DateTime.now().year, (_selectedDate?.month ?? DateTime.now().month) + 1, 0).day,
                                  (i) => i + 1,
                                ).map((d) => DropdownMenuItem(
                                  value: d,
                                  child: Center(
                                    child: Text(
                                      d.toString().padLeft(2, '0'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ),
                                )).toList(),
                                onChanged: (day) {
                                  if (day != null) {
                                    setState(() {
                                      _selectedDate = DateTime(_selectedDate!.year, _selectedDate!.month, day);
                                    });
                                    _loadPointsForSelectedDate();
                                  }
                                },
                              ),
                            ),
                          ),
                          const Text('/', style: TextStyle(color: Colors.grey, fontSize: 14)),
                          // Month Dropdown
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedDate?.month,
                                items: List.generate(12, (i) => i + 1).map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Center(
                                    child: Text(
                                      m.toString().padLeft(2, '0'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ),
                                )).toList(),
                                onChanged: (month) {
                                  if (month != null) {
                                    final daysInMonth = DateTime(_selectedDate!.year, month + 1, 0).day;
                                    final targetDay = _selectedDate!.day.clamp(1, daysInMonth);
                                    setState(() {
                                      _selectedDate = DateTime(_selectedDate!.year, month, targetDay);
                                    });
                                    _loadPointsForSelectedDate();
                                  }
                                },
                              ),
                            ),
                          ),
                          const Text('/', style: TextStyle(color: Colors.grey, fontSize: 14)),
                          // Year Dropdown
                          Expanded(
                            flex: 2,
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedDate?.year,
                                items: List.generate(DateTime.now().year - 2000 + 1, (i) => 2000 + i).map((y) => DropdownMenuItem(
                                  value: y,
                                  child: Center(
                                    child: Text(
                                      y.toString(),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ),
                                )).toList(),
                                onChanged: (year) {
                                  if (year != null) {
                                    final daysInMonth = DateTime(year, _selectedDate!.month + 1, 0).day;
                                    final targetDay = _selectedDate!.day.clamp(1, daysInMonth);
                                    setState(() {
                                      _selectedDate = DateTime(year, _selectedDate!.month, targetDay);
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
                    icon: Icon(_showCalendar ? Icons.calendar_today : Icons.calendar_month),
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
                                  ? 'Timeline Path'
                                  : 'Track Details (${points.length} pts)',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: Icon(_viewAsPath ? Icons.list : Icons.timeline),
                              onPressed: () {
                                setState(() {
                                  _viewAsPath = !_viewAsPath;
                                });
                              },
                              tooltip: _viewAsPath ? 'Show Raw List' : 'Show Timeline Path',
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
                                final timelineItems = _clusterTimeline(points, offset);
                                if (timelineItems.isEmpty) {
                                  return const Center(
                                    child: Text('No timeline points.'),
                                  );
                                }
                                return ListView.builder(
                                  itemCount: timelineItems.length,
                                  itemBuilder: (context, idx) {
                                    final isSelected = _selectedTimelineItemIndex == idx;
                                    final isFirst = idx == 0;
                                    final isLast = idx == timelineItems.length - 1;
                                    return _buildTimelineItem(
                                        context, timelineItems, idx, offset, isSelected, isFirst, isLast);
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
                                    fontFamily: 'monospace', fontSize: 10),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 16),
                                    onPressed: isEditing
                                        ? null
                                        : () => _openEditPointDialog(context,
                                            appState, dateInfo, points, idx),
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
                                              builder: (ctx) => AlertDialog(
                                                title:
                                                    const Text('Delete Point'),
                                                content: const Text(
                                                    'Delete this coordinate point from the timeline?'),
                                                actions: [
                                                  TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              ctx, false),
                                                      child:
                                                          const Text('Cancel')),
                                                  ElevatedButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            ctx, true),
                                                    style: ElevatedButton
                                                        .styleFrom(
                                                            backgroundColor:
                                                                Colors.red,
                                                            foregroundColor:
                                                                Colors.white),
                                                    child: const Text('Delete'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              final newPts =
                                                  List<LocationPoint>.from(
                                                      points)
                                                    ..removeAt(idx);
                                              await appState.saveListPoints(
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

  TileLayer _buildTileLayer(String mapProvider) {
    String urlTemplate;
    TileProvider? tileProvider;

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
    LatLng? selectedStayPointCenter;
    MoveSegmentItem? selectedMoveSegment;

    if (_viewAsPath && _selectedTimelineItemIndex != null && _selectedTimelineItemIndex! < timelineItems.length) {
      final selectedItem = timelineItems[_selectedTimelineItemIndex!];
      if (selectedItem is StayPointItem) {
        selectedStayPointCenter = selectedItem.center;
      } else if (selectedItem is MoveSegmentItem) {
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
        // Render each MoveSegmentItem as a separate polyline with conditional colors/thickness
        for (final item in timelineItems) {
          if (item is MoveSegmentItem && item.points.isNotEmpty) {
            final isCurrentSelected = (selectedMoveSegment == item);
            final hasAnySelection = (selectedMoveSegment != null);

            Color lineColor;
            double width;

            if (hasAnySelection) {
              if (isCurrentSelected) {
                lineColor = TimelineConstants.activeRouteColor; // Bold active route
                width = TimelineConstants.polylineStrokeWidthSelected;
              } else {
                lineColor = TimelineConstants.activeRouteColor.withValues(alpha: 0.15); // Faded route
                width = TimelineConstants.polylineStrokeWidthUnselected;
              }
            } else {
              lineColor = TimelineConstants.activeRouteColor; // Default bold route
              width = TimelineConstants.polylineStrokeWidthDefault;
            }

            // Create a continuous, connected path segment by pre-pending and post-pending neighboring coordinates
            final List<LatLng> pathLatLngs = [];
            final startIdx = pointsToShow.indexOf(item.points.first);
            if (startIdx > 0) {
              pathLatLngs.add(pointsToShow[startIdx - 1].latLng);
            }
            pathLatLngs.addAll(item.points.map((p) => p.latLng));
            final endIdx = pointsToShow.indexOf(item.points.last);
            if (endIdx >= 0 && endIdx < pointsToShow.length - 1) {
              pathLatLngs.add(pointsToShow[endIdx + 1].latLng);
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

    // Selected Stay Point marker
    if (!isEditing && selectedStayPointCenter != null) {
      markers.add(
        Marker(
          point: selectedStayPointCenter,
          width: 36,
          height: 36,
          child: Container(
            decoration: BoxDecoration(
              color: TimelineConstants.stayPointIconColor, // Brown stay point icon
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: const Icon(Icons.place, color: Colors.white, size: 18),
          ),
        ),
      );
    }

    // Selected Move Segment start and end point markers
    if (!isEditing && selectedMoveSegment != null && selectedMoveSegment.points.isNotEmpty) {
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
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
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
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      );
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
                  color: _hoveredColor ?? const Color(0xFF7F92FF),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
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
                        DateFormat('yyyy-MM-dd').format(localHoverTime),
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 10),
                      ),
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

    return MapWidget(
      mapController: _mapController,
      tileLayer: tileLayer,
      polylines: polylines,
      markers: markers,
      isEditing: isEditing,
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

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: _sidebarWidth,
            color: Theme.of(context).colorScheme.surface,
            child:
                _buildSidebar(context, appState, currentDateInfo, pointsToShow),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (details) {
              setState(() {
                _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(280.0, 800.0);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: Container(
                width: 8,
                color: Colors.transparent,
                child: const Center(
                  child: VerticalDivider(width: 1, thickness: 1),
                ),
              ),
            ),
          ),
          // Map Panel
          Expanded(
            child: Stack(
              children: [
                _buildMap(context, appState, settings, pointsToShow),

                 // Map mode toggle
                if (!isEditing && currentDateInfo.filePath.isNotEmpty)
                  Positioned(
                    top: 16,
                    left: _showCalendar ? 350 : 16,
                    child: FloatingActionButton.extended(
                      heroTag: 'edit_route',
                      onPressed: () {
                        appState.startEditing(currentDateInfo.filePath);
                      },
                      icon: const Icon(Icons.edit_road),
                      label: const Text('Edit Path Coordinates'),
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      foregroundColor:
                          Theme.of(context).colorScheme.onPrimaryContainer,
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
                          onDateSelected: (date) {
                            setState(() {
                              _selectedDate = date;
                            });
                            _loadPointsForSelectedDate();
                          },
                          onClose: () {
                            setState(() {
                              _showCalendar = false;
                            });
                          },
                        ),
                      ),
                    ),
                  ),

                // Save / Cancel Floating Buttons
                if (isEditing)
                  Positioned(
                    bottom: 20,
                    left: 16,
                    child: Row(
                      children: [
                        FloatingActionButton.extended(
                          heroTag: 'save_edit',
                          onPressed: () async {
                            await appState.saveEditingChanges(timeOffset);
                            setState(() {
                              _selectedPointIndex = null;
                            });
                            _loadPointsForSelectedDate();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Timeline edits saved successfully.')),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) {
      return '${h}h ${m}m';
    } else {
      return '${m}m';
    }
  }

  List<TimelineItem> _clusterTimelineRaw(List<LocationPoint> points, double timezoneOffset) {
    if (points.isEmpty) return [];
    if (points.length < 2) {
      return [
        StayPointItem(
          points: points,
          startTime: points.first.timestamp,
          endTime: points.first.timestamp,
          center: points.first.latLng,
        )
      ];
    }

    final List<TimelineItem> items = [];
    final double distThreshold = TimelineConstants.stayPointDistanceThreshold; // meters
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
        final center = LatLng(latSum / stayPoints.length, lngSum / stayPoints.length);

        items.add(StayPointItem(
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
            final d = GeoUtils.distanceBetween(points[m].latLng, nextJ < n ? points[nextJ].latLng : points[m].latLng);
            if (d < distThreshold) {
              nextJ++;
            } else {
              break;
            }
          }
          final nextDur = points[nextJ - 1].timestamp.difference(points[m].timestamp);
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
          distSum += GeoUtils.distanceBetween(pathPoints[m].latLng, pathPoints[m + 1].latLng);
        }

        final startTime = (i > 0) ? points[i - 1].timestamp : points[i].timestamp;
        final endTime = (nextStayStart < n) ? points[nextStayStart].timestamp : points[nextStayStart - 1].timestamp;

        items.add(MoveSegmentItem(
          points: movePoints,
          startTime: startTime,
          endTime: endTime,
          distance: distSum,
        ));

        i = nextStayStart;
      }
    }

    return items;
  }

  List<TimelineItem> _clusterTimeline(List<LocationPoint> points, double timezoneOffset) {
    final List<TimelineItem> rawItems = _clusterTimelineRaw(points, timezoneOffset);

    if (_previousDayLastStayPoint != null && _selectedDate != null) {
      final currentDayMidnight = DateTime.utc(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        0, 0, 0,
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

          final initialStay = StayPointItem(
            points: stayPoints,
            startTime: currentDayMidnight,
            endTime: firstItem.startTime,
            center: LatLng(_previousDayLastStayPoint!.latitude, _previousDayLastStayPoint!.longitude),
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

        final initialStay = StayPointItem(
          points: stayPoints,
          startTime: currentDayMidnight,
          endTime: currentDayEnd,
          center: LatLng(_previousDayLastStayPoint!.latitude, _previousDayLastStayPoint!.longitude),
        );

        rawItems.add(initialStay);
      }
    }

    return rawItems;
  }

  Widget _buildTimelineItem(
      BuildContext context, List<TimelineItem> allItems, int index, double timezoneOffset, bool isSelected, bool isFirst, bool isLast) {
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

    if (item is StayPointItem) {
      final startTime = _formatPointTime(item.startTime, timezoneOffset);
      final endTime   = _formatPointTime(item.endTime,   timezoneOffset);
      final durationStr = _formatDuration(item.duration);
      final coordStr = '${item.center.latitude.toStringAsFixed(5)}, ${item.center.longitude.toStringAsFixed(5)}';

      return _TimelineTileWrapper(
        isSelected: isSelected,
        onTap: () {
          setState(() {
            _selectedTimelineItemIndex = index;
          });
          _animatedMapMove(item.center, 16.5);
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
                      child: const Icon(Icons.place, color: Colors.white, size: 20),
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
                                color: isFirst ? Colors.transparent : lineActiveColor,
                              ),
                            ),
                            Expanded(
                              child: Container(
                                width: TimelineConstants.timelineLineThickness,
                                color: isLast ? Colors.transparent : lineActiveColor,
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Place name box
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        'Stay Point (${item.points.length} pts)',
                                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.arrow_drop_down, size: 18),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Coordinates
                              Text(
                                coordStr,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(height: 2),
                              // Time range + duration
                              Text(
                                '$startTime – $endTime  ($durationStr)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
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
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert, size: 18,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                                  _copyJsonWithNeighbors(context, allItems, index);
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (item is MoveSegmentItem) {
      final durationStr = _formatDuration(item.duration);
      final distStr = item.distance < 1000
          ? '${item.distance.toStringAsFixed(0)} m'
          : '${(item.distance / 1000).toStringAsFixed(2)} km';

      return _TimelineTileWrapper(
        isSelected: isSelected,
        onTap: () {
          setState(() {
            _selectedTimelineItemIndex = index;
          });
          if (item.points.isNotEmpty) {
            final bounds = LatLngBounds.fromPoints(
              item.points.map((p) => p.latLng).toList(),
            );
            _mapController.fitCamera(
              CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
            );
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: _buildTransitIcons(item.points),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$durationStr  ·  $distStr',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert, size: 18,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                          padding: EdgeInsets.zero,
                          itemBuilder: (context) => [
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
                            if (val == 'snap_osrm') {
                              final appState = context.read<AppStateProvider>();
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
                              final dayPoints = appState.activePaths[dateInfo.filePath] ?? [];
                              _snapSegmentToRoads(context, appState, dateInfo, dayPoints, item);
                            } else if (val == 'copy_json') {
                              _copySegmentJson(context, item);
                            } else if (val == 'copy_json_neighbors') {
                              _copyJsonWithNeighbors(context, allItems, index);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  List<String> _getTransitModes(List<LocationPoint> points) {
    final List<String> modes = [];
    String? lastMode;

    for (final p in points) {
      final mode = p.activityType;
      if (mode != null && mode.isNotEmpty) {
        if (mode != lastMode) {
          modes.add(mode);
          lastMode = mode;
        }
      }
    }

    if (modes.isEmpty) {
      modes.add('IN_PASSENGER_VEHICLE');
    }

    return modes;
  }

  IconData _getTransitIcon(String mode) {
    final norm = mode.toUpperCase();
    if (norm.contains('WALK') || norm.contains('FOOT') || norm.contains('RUN')) {
      return Icons.directions_walk;
    }
    if (norm.contains('BIKE') || norm.contains('BICYCLE') || norm.contains('CYCLE')) {
      return Icons.directions_bike;
    }
    if (norm.contains('BUS')) {
      return Icons.directions_bus;
    }
    if (norm.contains('TRAIN') || norm.contains('SUBWAY') || norm.contains('RAIL')) {
      return Icons.directions_railway;
    }
    if (norm.contains('FLY') || norm.contains('AIR')) {
      return Icons.local_airport;
    }
    if (norm.contains('SAIL') || norm.contains('BOAT') || norm.contains('SHIP')) {
      return Icons.directions_boat;
    }
    return Icons.directions_car;
  }

  List<Widget> _buildTransitIcons(List<LocationPoint> points) {
    final modes = _getTransitModes(points);
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

  Future<void> _snapSegmentToRoads(
      BuildContext context,
      AppStateProvider appState,
      DateInfo dateInfo,
      List<LocationPoint> dayPoints,
      MoveSegmentItem segment) async {
    if (segment.points.isEmpty) return;

    final settings = context.read<SettingsProvider>();
    final useGoogle = settings.routingProvider == 'google';
    final googleApiKey = settings.googleMapsApiKey;

    if (useGoogle && googleApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please configure your Google Maps API Key in Settings.')),
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
                Text(useGoogle ? 'Routing segment with Google Roads API...' : 'Routing segment with OSRM...'),
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
        final end = (start + 100 < originalPoints.length) ? start + 100 : originalPoints.length;
        final chunk = originalPoints.sublist(start, end);
        final pathString = chunk.map((p) => '${p.latitude},${p.longitude}').join('|');

        final url = 'https://roads.googleapis.com/v1/snapToRoads?path=$pathString&interpolate=true&key=$googleApiKey';

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
            debugPrint('Google Roads API error: Status code ${response.statusCode}');
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
          if (origIdx != null && origIdx >= 0 && origIdx < originalPoints.length) {
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
              final totalDuration = segment.endTime.difference(segment.startTime);
              timestamp = segment.startTime.add(totalDuration * (k / (snappedPoints.length - 1)));
            }
          }

          newPoints.add(LocationPoint(
            latitude: lat,
            longitude: lng,
            timestamp: timestamp,
            activityType: segment.points.isNotEmpty ? segment.points.first.activityType : 'IN_PASSENGER_VEHICLE',
          ));
        }
      }
    } else {
      // OSRM routing
      final startPoint = segment.points.first;
      final endPoint = segment.points.last;
      final url = 'https://router.project-osrm.org/route/v1/driving/'
          '${startPoint.longitude},${startPoint.latitude};${endPoint.longitude},${endPoint.latitude}'
          '?overview=full&geometries=geojson';

      final client = HttpClient();
      List<LatLng> routedCoords = [];
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final data = jsonDecode(responseBody);
          if (data['routes'] != null && data['routes'].isNotEmpty) {
            final geometry = data['routes'][0]['geometry'];
            final coordinates = geometry['coordinates'] as List;
            routedCoords = coordinates.map((coord) {
              final lng = coord[0] as double;
              final lat = coord[1] as double;
              return LatLng(lat, lng);
            }).toList();
          }
        }
      } catch (e) {
        routingSuccess = false;
        debugPrint('OSRM routing failed: $e');
      } finally {
        client.close();
      }

      if (routingSuccess && routedCoords.isNotEmpty) {
        final List<double> cumulativeDistances = [0.0];
        double totalDist = 0.0;
        for (int k = 0; k < routedCoords.length - 1; k++) {
          final d = GeoUtils.distanceBetween(routedCoords[k], routedCoords[k + 1]);
          totalDist += d;
          cumulativeDistances.add(totalDist);
        }

        final totalDuration = segment.endTime.difference(segment.startTime);
        for (int k = 0; k < routedCoords.length; k++) {
          final ratio = totalDist > 0 ? (cumulativeDistances[k] / totalDist) : (k / (routedCoords.length - 1));
          final timestamp = segment.startTime.add(totalDuration * ratio);
          newPoints.add(LocationPoint(
            latitude: routedCoords[k].latitude,
            longitude: routedCoords[k].longitude,
            timestamp: timestamp,
            activityType: segment.points.isNotEmpty ? segment.points.first.activityType : 'IN_PASSENGER_VEHICLE',
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
          SnackBar(content: Text('Failed to route segment using ${useGoogle ? 'Google Roads API' : 'OSRM'}.')),
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

    await appState.saveListPoints(dateInfo, updatedPoints);
    _loadPointsForSelectedDate();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Segment successfully snapped to roads!')),
      );
    }
  }

  void _copyToClipboard(BuildContext context, String text, String successMessage) {
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
    final pointsJson = item is StayPointItem
        ? item.points.map(_pointToTimelineJson).toList()
        : (item as MoveSegmentItem).points.map(_pointToTimelineJson).toList();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(pointsJson);
    _copyToClipboard(context, jsonStr, 'Segment JSON copied to clipboard!');
  }

  void _copyJsonWithNeighbors(BuildContext context, List<TimelineItem> allItems, int currentIndex) {
    final ctrl = TextEditingController(text: '2');
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Copy JSON with Neighbors'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter number of neighboring segments to include before & after:'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
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

              final start = (currentIndex - neighbors).clamp(0, allItems.length - 1);
              final end = (currentIndex + neighbors).clamp(0, allItems.length - 1);

              final List<Map<String, dynamic>> output = [];
              for (int i = start; i <= end; i++) {
                final item = allItems[i];
                final isCurrent = i == currentIndex;
                
                final String type = item is StayPointItem ? 'stay_point' : 'move_segment';
                final List<LocationPoint> pts = item is StayPointItem ? item.points : (item as MoveSegmentItem).points;

                output.add({
                  'segmentIndex': i,
                  'isTargetSegment': isCurrent,
                  'type': type,
                  'startTime': item.startTime.toUtc().toIso8601String(),
                  'endTime': item.endTime.toUtc().toIso8601String(),
                  'points': pts.map(_pointToTimelineJson).toList(),
                });
              }

              final jsonStr = const JsonEncoder.withIndent('  ').convert(output);
              _copyToClipboard(context, jsonStr, 'JSON with neighbors copied to clipboard!');
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
      backgroundColor = Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.25);
    } else if (_isHovered) {
      backgroundColor = Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
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
  final List<Marker> markers;
  final bool isEditing;
  final Function(PointerHoverEvent, LatLng) onHover;
  final Function(PointerDownEvent) onPointerDown;
  final Function(PointerMoveEvent) onPointerMove;
  final Function(PointerUpEvent) onPointerUp;
  final ProjectionResult? hoveredProjection;
  final List<LocationPoint> pointsToShow;
  final double timezoneOffset;
  final String Function(DateTime, double) formatPointTime;

  const MapWidget({
    super.key,
    required this.mapController,
    required this.tileLayer,
    required this.polylines,
    required this.markers,
    required this.isEditing,
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
      onPointerDown: onPointerDown,
      onPointerMove: onPointerMove,
      onPointerUp: onPointerUp,
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
                  flags: isEditing
                      ? InteractiveFlag.all & ~InteractiveFlag.drag
                      : InteractiveFlag.all,
                ),
              ),
              children: [
                tileLayer,
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

  const CustomCalendarDialog({
    super.key,
    required this.initialDate,
    required this.allDates,
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
                    cellColor = Colors.grey.shade200;
                    textColor = Colors.grey.shade800;
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
                    child: Text(
                      day.toString(),
                      style: TextStyle(
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: textColor,
                      ),
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
        DateTime(widget.selectedDate.year, widget.selectedDate.month + 1, 0).day;
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
      distances = List.generate(
          daysInMonth, (i) => monthData[i + 1]?.distance ?? 0.0);
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
      maxDist = distances.fold(
          1.0, (maxVal, val) => val > maxVal ? val : maxVal);
      labels = List.generate(12, (index) =>
          DateFormat('MMM').format(DateTime(2020, index + 1)));
    } else {
      // Show 7 years centered around the selected year
      final currentYear = widget.selectedDate.year;
      final List<int> years = List.generate(7, (i) => currentYear - 3 + i);
      itemCount = 7;
      distances = years.map((y) => widget.allDates.where((d) => d.date.year == y).fold(0.0, (sum, d) => sum + d.distance)).toList();
      labels = years.map((y) => y.toString()).toList();
      maxDist = distances.fold(1.0, (maxVal, val) => val > maxVal ? val : maxVal);
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
        final monthName = DateFormat('MMMM').format(
            DateTime(widget.selectedDate.year, _hoveredIndex! + 1));
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
                          widget.onDateSelected(widget.selectedDate.subtract(const Duration(days: 1)));
                        } else if (_mode == 'monthly') {
                          final newMonth = widget.selectedDate.month == 1 ? 12 : widget.selectedDate.month - 1;
                          final newYear = widget.selectedDate.month == 1 ? widget.selectedDate.year - 1 : widget.selectedDate.year;
                          final daysInNewMonth = DateTime(newYear, newMonth + 1, 0).day;
                          final targetDay = widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(newYear, newMonth, targetDay));
                        } else {
                          final newYear = widget.selectedDate.year - 1;
                          final daysInNewMonth = DateTime(newYear, widget.selectedDate.month + 1, 0).day;
                          final targetDay = widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(newYear, widget.selectedDate.month, targetDay));
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
                          widget.onDateSelected(widget.selectedDate.add(const Duration(days: 1)));
                        } else if (_mode == 'monthly') {
                          final newMonth = widget.selectedDate.month == 12 ? 1 : widget.selectedDate.month + 1;
                          final newYear = widget.selectedDate.month == 12 ? widget.selectedDate.year + 1 : widget.selectedDate.year;
                          final daysInNewMonth = DateTime(newYear, newMonth + 1, 0).day;
                          final targetDay = widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(newYear, newMonth, targetDay));
                        } else {
                          final newYear = widget.selectedDate.year + 1;
                          final daysInNewMonth = DateTime(newYear, widget.selectedDate.month + 1, 0).day;
                          final targetDay = widget.selectedDate.day.clamp(1, daysInNewMonth);
                          widget.onDateSelected(DateTime(newYear, widget.selectedDate.month, targetDay));
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
                    final List<int> years = List.generate(7, (i) => currentYear - 3 + i);
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
                        final List<int> years = List.generate(7, (i) => currentYear - 3 + i);
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

class BingTileProvider extends NetworkTileProvider {
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

class StayPointItem extends TimelineItem {
  final List<LocationPoint> points;
  @override
  final DateTime startTime;
  @override
  final DateTime endTime;
  final LatLng center;

  StayPointItem({
    required this.points,
    required this.startTime,
    required this.endTime,
    required this.center,
  });

  Duration get duration => endTime.difference(startTime);
}

class MoveSegmentItem extends TimelineItem {
  final List<LocationPoint> points;
  @override
  final DateTime startTime;
  @override
  final DateTime endTime;
  final double distance;

  MoveSegmentItem({
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
  final Function(DateTime) onDateSelected;
  final VoidCallback onClose;

  const CustomCalendarInline({
    super.key,
    required this.selectedDate,
    required this.allDates,
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
    final firstDayOfWeek = DateTime(_displayYear, _displayMonth, 1).weekday; // 1 = Monday, 7 = Sunday
    final paddingCount = firstDayOfWeek - 1;

    final monthName = DateFormat('MMMM yyyy').format(DateTime(_displayYear, _displayMonth));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
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
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                  cellColor = Colors.grey.shade200;
                  textColor = Colors.grey.shade800;
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
                  child: Text(
                    day.toString(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected
                          ? Theme.of(context).colorScheme.onPrimary
                          : textColor,
                    ),
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
