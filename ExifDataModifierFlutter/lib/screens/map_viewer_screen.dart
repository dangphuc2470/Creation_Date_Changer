import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/location_point.dart';
import '../providers/app_state_provider.dart';
import '../providers/settings_provider.dart';

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

ProjectionResult? _getNearestProjection(LatLng cursor, List<LocationPoint> points) {
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

class _MapViewerScreenState extends State<MapViewerScreen> {
  final MapController _mapController = MapController();

  // Hover state (non-edit mode)
  LocationPoint? _hoveredPoint;
  Color? _hoveredColor;
  LatLng? _hoveredLatLng;
  ProjectionResult? _hoveredProjection; // Hover state (edit mode)

  // Selected point index (edit mode)
  int? _selectedPointIndex;
  bool _isDraggingPoint = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitBounds();
    });
  }

  void _fitBounds() {
    final appState = context.read<AppStateProvider>();
    final paths = appState.activePaths;
    if (paths.isEmpty) return;

    final allPoints = paths.values
        .expand((points) => points.map((p) => p.latLng))
        .toList();
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
      final pathColors = appState.pathColors;
      if (paths.isEmpty) return;

      LocationPoint? closestPoint;
      Color? closestColor;
      double minDistance = double.infinity;
      const double snapThreshold = 0.005;

      for (final entry in paths.entries) {
        final color = pathColors[entry.key] ?? const Color(0xFF7F92FF);
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

    // 1. Check if click is close to an existing visible marker (pinned or selected)
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
    final pinnedIndices = appState.pinnedPointIndices;

    int? clickedIndex;
    double minDistanceSq = double.infinity;

    for (int i = 0; i < editingPoints.length; i++) {
      if (pinnedIndices.contains(i) || _selectedPointIndex == i) {
        final pt = editingPoints[i];
        final dLat = pt.latitude - tapLatLng.latitude;
        final dLon = pt.longitude - tapLatLng.longitude;
        final distSq = dLat * dLat + dLon * dLon;

        if (distSq < minDistanceSq && distSq < touchThresholdSq) {
          minDistanceSq = distSq;
          clickedIndex = i;
        }
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

    // 2. Click is not near any existing marker. Check if close to the line (hover projection)
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
        final newLatLng = _mapController.camera.screenOffsetToLatLng(localOffset);
        appState.updatePointCoordinate(_selectedPointIndex!, newLatLng);
      } catch (_) {}
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_isDraggingPoint) {
      setState(() {
        _isDraggingPoint = false;
      });
    }
  }

  DateTime _getHoverTime(ProjectionResult proj, List<LocationPoint> points) {
    final index = proj.insertIndex;
    if (index < 1 || index > points.length) return DateTime.now();
    final tPrev = points[index - 1].timestamp;
    final tNext = points[index].timestamp;
    final diffMs = tNext.difference(tPrev).inMilliseconds;
    return tPrev.add(Duration(milliseconds: (diffMs * proj.t).toInt()));
  }

  Widget _buildTileLayer(String mapProvider) {
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
      userAgentPackageName: 'com.example.exifmodifier',
    );
  }

  Future<DateTime?> _selectDateTime(BuildContext context, DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute, initial.second);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final paths = appState.activePaths;
    final pathColors = appState.pathColors;
    final settings = context.watch<SettingsProvider>();
    final mapProvider = settings.mapProvider;
    final timeOffset = settings.geotagTimezone.toDouble();

    final isEditing = appState.isEditing;
    final editingPoints = appState.editingPoints;
    final pinnedIndices = appState.pinnedPointIndices;

    if (paths.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.map, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                'No Paths Selected',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Select dates from Location Manager to view on map'),
            ],
          ),
        ),
      );
    }

    // Determine markers to render in edit mode
    List<Marker> editMarkers = [];
    if (isEditing && editingPoints.isNotEmpty) {
      final List<IndexPoint> allIndexPoints = editingPoints.asMap().entries
          .map((e) => IndexPoint(e.key, e.value))
          .toList();

      final visibleIndexPoints = allIndexPoints
          .where((ip) => pinnedIndices.contains(ip.index) || _selectedPointIndex == ip.index)
          .toList();

      editMarkers = visibleIndexPoints.map((ip) {
        final isPinned = pinnedIndices.contains(ip.index);
        final isSelected = _selectedPointIndex == ip.index;
        final isAnchor = ip.index == 0 || ip.index == editingPoints.length - 1;

        final localTime = ip.point.timestamp.add(Duration(minutes: (timeOffset * 60).toInt()));

        return Marker(
          point: ip.point.latLng,
          width: 140,
          height: 70,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                bottom: 10,
                child: Container(
                  width: isSelected ? 16 : 12,
                  height: isSelected ? 16 : 12,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.amber
                        : (isPinned ? Colors.red : Colors.white),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected || isPinned ? Colors.white : Colors.black38,
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                ),
              ),
              if (isSelected)
                Positioned(
                  bottom: 32,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 4),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isAnchor)
                          GestureDetector(
                            onTap: () {
                              appState.togglePin(ip.index);
                            },
                            child: Icon(
                              isPinned ? Icons.lock : Icons.lock_open,
                              size: 13,
                              color: isPinned ? Colors.redAccent : Colors.white70,
                            ),
                          )
                        else
                          const Icon(Icons.lock, size: 12, color: Colors.white60),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () async {
                            final newDT = await _selectDateTime(context, localTime);
                            if (newDT != null) {
                              final utcTime = newDT.subtract(Duration(minutes: (timeOffset * 60).toInt()));
                              appState.updatePointTimeAndInterpolate(ip.index, utcTime);
                            }
                          },
                          child: Text(
                            DateFormat('HH:mm:ss').format(localTime),
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      }).toList();

      // Render the static hover point marker with time popup
      if (_hoveredLatLng != null && _hoveredProjection != null && !_isDraggingPoint) {
        final hoverTime = _getHoverTime(_hoveredProjection!, editingPoints);
        final localHoverTime = hoverTime.add(Duration(minutes: (timeOffset * 60).toInt()));

        editMarkers.add(
          Marker(
            point: _hoveredLatLng!,
            width: 120,
            height: 70,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  bottom: 10,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black54, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 4),
                      ],
                    ),
                    child: const Icon(
                      Icons.add,
                      size: 8,
                      color: Colors.black54,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 30,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      DateFormat('HH:mm:ss').format(localHoverTime),
                      style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    return Scaffold(
      body: Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: isEditing && editingPoints.isNotEmpty
                    ? editingPoints.first.latLng
                    : paths.values.first.first.latLng,
                initialZoom: 13,
                onPointerHover: _handleHover,
                onTap: (tapPosition, point) {
                  setState(() {
                    _selectedPointIndex = null;
                  });
                },
                interactionOptions: InteractionOptions(
                  flags: isEditing && (_hoveredLatLng != null || _isDraggingPoint)
                      ? (InteractiveFlag.all & ~InteractiveFlag.drag)
                      : InteractiveFlag.all,
                ),
              ),
              children: [
                _buildTileLayer(mapProvider),
                PolylineLayer(
                  polylines: isEditing
                      ? [
                          Polyline(
                            points: editingPoints.map((p) => p.latLng).toList(),
                            strokeWidth: 7,
                            color: Colors.white,
                          ),
                          Polyline(
                            points: editingPoints.map((p) => p.latLng).toList(),
                            strokeWidth: 4,
                            color: const Color(0xFF7A7E85),
                          ),
                        ]
                      : (paths.length == 1
                          ? [
                              Polyline(
                                points: paths.values.first.map((p) => p.latLng).toList(),
                                strokeWidth: 7,
                                color: Colors.white,
                              ),
                              Polyline(
                                points: paths.values.first.map((p) => p.latLng).toList(),
                                strokeWidth: 4,
                                color: const Color(0xFF7A7E85),
                              ),
                            ]
                          : paths.entries.map((entry) {
                              return Polyline(
                                points: entry.value.map((p) => p.latLng).toList(),
                                strokeWidth: 4,
                                color: pathColors[entry.key] ?? const Color(0xFF7F92FF),
                              );
                            }).toList()),
                ),
                if (isEditing) MarkerLayer(markers: editMarkers),
                if (!isEditing && _hoveredPoint != null && _hoveredLatLng != null)
                  MarkerLayer(
                    markers: [
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
                                color: _hoveredColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2.5),
                                boxShadow: const [
                                  BoxShadow(color: Colors.black38, blurRadius: 6),
                                ],
                              ),
                            ),
                            Positioned(
                              bottom: 75,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.85),
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black45,
                                        blurRadius: 4,
                                        offset: Offset(0, 2)),
                                  ],
                                ),
                                child: Builder(builder: (context) {
                                  final displayTime = _hoveredPoint!.timestamp.add(
                                    Duration(minutes: (timeOffset * 60).toInt()),
                                  );
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        DateFormat('yyyy-MM-dd')
                                            .format(displayTime),
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 10,
                                        ),
                                      ),
                                      Text(
                                        DateFormat('HH:mm:ss').format(displayTime),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  );
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            // Edit Mode Banner at Top
            if (isEditing)
              Positioned(
                top: 16,
                left: 100,
                right: 100,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade900.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'EDIT MODE: Drag path to insert a point. Tap popup to edit lock & time.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            // Map Controls & Legend (only if not editing)
            if (!isEditing) ...[
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                  ),
                  child: DropdownButton<String>(
                    value: mapProvider,
                    underline: const SizedBox(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        context.read<SettingsProvider>().updateMapProvider(newValue);
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                          value: 'google_roadmap',
                          child: Text('Google Maps')),
                      DropdownMenuItem(
                          value: 'google_satellite',
                          child: Text('Google Satellite')),
                      DropdownMenuItem(
                          value: 'bing_roadmap', child: Text('Bing Maps')),
                      DropdownMenuItem(
                          value: 'bing_satellite',
                          child: Text('Bing Satellite')),
                      DropdownMenuItem(
                          value: 'osm', child: Text('OpenStreetMap')),
                    ],
                  ),
                ),
              ),
              // Selection Info / Legend & Edit Triggers
              Positioned(
                bottom: 16,
                right: 16,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Legend (${paths.length} paths)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Divider(),
                        ...paths.keys.map((key) {
                          final color = pathColors[key] ?? const Color(0xFF7F92FF);
                          final fileName = key.split('\\').last.split('/').last;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: paths.length == 1 ? const Color(0xFF7A7E85) : color,
                                    border: paths.length == 1
                                        ? Border.all(color: Colors.white, width: 1.5)
                                        : null,
                                    boxShadow: paths.length == 1
                                        ? const [BoxShadow(color: Colors.black26, blurRadius: 1)]
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    fileName,
                                    style: const TextStyle(fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                    constraints: const BoxConstraints(),
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(Icons.edit, size: 16, color: Colors.grey),
                                    onPressed: () {
                                      appState.startEditing(key);
                                      setState(() {
                                        _selectedPointIndex = null;
                                        _hoveredLatLng = null;
                                        _hoveredProjection = null;
                                      });
                                    }),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            // Zoom controls
            Positioned(
              top: 16,
              right: 16,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'zoom_in',
                    onPressed: () => _mapController.move(
                        _mapController.camera.center,
                        _mapController.camera.zoom + 1),
                    child: const Icon(Icons.add),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoom_out',
                    onPressed: () => _mapController.move(
                        _mapController.camera.center,
                        _mapController.camera.zoom - 1),
                    child: const Icon(Icons.remove),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'fit_bounds',
                    onPressed: _fitBounds,
                    child: const Icon(Icons.center_focus_strong),
                  ),
                ],
              ),
            ),
            // Save / Cancel Floating Buttons (positioned closer to bottom now that sheet is gone)
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
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Timeline edits saved successfully.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
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
    );
  }
}

class BingTileProvider extends NetworkTileProvider {
  BingTileProvider();

  @override
  String getTileUrl(TileCoordinates coords, TileLayer options) {
    final x = coords.x;
    final y = coords.y;
    final z = coords.z;
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
