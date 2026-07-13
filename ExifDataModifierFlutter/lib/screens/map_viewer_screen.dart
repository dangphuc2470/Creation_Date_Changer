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
import '../services/location_manager.dart';
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

  // Hover state (non-edit mode)
  LocationPoint? _hoveredPoint;
  Color? _hoveredColor;
  LatLng? _hoveredLatLng;
  ProjectionResult? _hoveredProjection; // Hover state (edit mode)

  // Selected point index (edit mode)
  int? _selectedPointIndex;
  bool _isDraggingPoint = false;

  void _loadPointsForSelectedDate() async {
    if (_selectedDate == null) return;
    final appState = context.read<AppStateProvider>();

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
    }
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
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      setState(() {
                        _selectedDate = _selectedDate!.subtract(const Duration(days: 1));
                      });
                      _loadPointsForSelectedDate();
                    },
                    tooltip: 'Previous Day',
                  ),
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
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () {
                      setState(() {
                        _selectedDate = _selectedDate!.add(const Duration(days: 1));
                      });
                      _loadPointsForSelectedDate();
                    },
                    tooltip: 'Next Day',
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.calendar_month),
                    onPressed: () async {
                      final date = await showDialog<DateTime>(
                        context: context,
                        builder: (ctx) => CustomCalendarDialog(
                          initialDate: _selectedDate ?? DateTime.now(),
                          allDates: appState.allDates,
                        ),
                      );
                      if (date != null) {
                        setState(() {
                          _selectedDate = date;
                        });
                        _loadPointsForSelectedDate();
                      }
                    },
                    tooltip: 'Choose Date',
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
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Track Details (${points.length} pts)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline,
                                  color: Colors.blue),
                              onPressed: isEditing
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
                        child: ListView.builder(
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
    if (pointsToShow.isNotEmpty) {
      polylines.add(
        Polyline(
          points: pointsToShow.map((p) => p.latLng).toList(),
          strokeWidth: isEditing ? 5.0 : 4.0,
          color: isEditing ? Colors.orange : const Color(0xFF7F92FF),
        ),
      );
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
          // Sidebar
          Container(
            width: 380,
            color: Theme.of(context).colorScheme.surface,
            child:
                _buildSidebar(context, appState, currentDateInfo, pointsToShow),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          // Map Panel
          Expanded(
            child: Stack(
              children: [
                _buildMap(context, appState, settings, pointsToShow),

                // Map mode toggle
                if (!isEditing && currentDateInfo.filePath.isNotEmpty)
                  Positioned(
                    top: 16,
                    left: 16,
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
  String _mode = 'monthly'; // 'daily', 'monthly', 'yearly'
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
    final currentDateInfo = widget.allDates.firstWhere(
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
    final totalDayDistance = currentDateInfo.distance;

    final totalMonthDistance = widget.allDates
        .where((d) =>
            d.date.year == widget.selectedDate.year &&
            d.date.month == widget.selectedDate.month)
        .fold(0.0, (sum, d) => sum + d.distance);

    final totalYearDistance = widget.allDates
        .where((d) => d.date.year == widget.selectedDate.year)
        .fold(0.0, (sum, d) => sum + d.distance);

    // 2. Prepare Mode Data
    int itemCount = 0;
    List<double> distances = [];
    List<String> labels = [];
    double maxDist = 1.0;
    
    // Monthly mode local vars
    final daysInMonth =
        DateTime(widget.selectedDate.year, widget.selectedDate.month + 1, 0).day;
    final Map<int, DateInfo> monthData = {};

    if (_mode == 'daily') {
      itemCount = 24;
      final hourlyDistances = List.filled(24, 0.0);
      if (widget.points.isNotEmpty) {
        for (int i = 0; i < widget.points.length - 1; i++) {
          final p1 = widget.points[i];
          final p2 = widget.points[i + 1];
          final localTime = p1.timestamp.add(
              Duration(minutes: (widget.timezoneOffset * 60).toInt()));
          final hour = localTime.hour;
          final dist = GeoUtils.distanceBetween(p1.latLng, p2.latLng);
          hourlyDistances[hour] += dist;
        }
      }
      distances = hourlyDistances;
      maxDist = distances.fold(
          1.0, (maxVal, val) => val > maxVal ? val : maxVal);
      labels = List.generate(24, (i) => i.toString().padLeft(2, '0'));
    } else if (_mode == 'monthly') {
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
    } else {
      // Yearly
      itemCount = 12;
      final yearlyDistances = List.filled(12, 0.0);
      for (int m = 1; m <= 12; m++) {
        yearlyDistances[m - 1] = widget.allDates
            .where((d) =>
                d.date.year == widget.selectedDate.year && d.date.month == m)
            .fold(0.0, (sum, d) => sum + d.distance);
      }
      distances = yearlyDistances;
      maxDist = distances.fold(
          1.0, (maxVal, val) => val > maxVal ? val : maxVal);
      labels = List.generate(12, (index) =>
          DateFormat('MMM').format(DateTime(2020, index + 1)));
    }

    // Header title and active hover description
    String titleText = 'Monthly Distance';
    String currentModeTotal = _formatDistance(totalMonthDistance);
    if (_mode == 'daily') {
      titleText = 'Daily Distance';
      currentModeTotal = _formatDistance(totalDayDistance);
    } else if (_mode == 'yearly') {
      titleText = 'Yearly Distance';
      currentModeTotal = _formatDistance(totalYearDistance);
    }

    Widget? hoverSubtitle;
    if (_hoveredIndex != null && _hoveredIndex! < itemCount) {
      if (_mode == 'daily') {
        hoverSubtitle = Text(
          'Hour ${_hoveredIndex!.toString().padLeft(2, '0')}:00: ${_formatDistance(distances[_hoveredIndex!])}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
      } else if (_mode == 'monthly') {
        final day = _hoveredIndex! + 1;
        hoverSubtitle = Text(
          'Day $day: ${_formatDistance(distances[_hoveredIndex!])}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        );
      } else {
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
                      ),
                      if (hoverSubtitle != null) ...[
                        const SizedBox(height: 2),
                        hoverSubtitle,
                      ],
                    ],
                  ),
                ),
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
                      DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                      DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
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
                    final localTimeNow = DateTime.now().add(
                        Duration(minutes: (widget.timezoneOffset * 60).toInt()));
                    isActive = index == localTimeNow.hour;
                  } else if (_mode == 'monthly') {
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
                  } else {
                    isActive = (index + 1) == widget.selectedDate.month;
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
                      if (_mode == 'monthly') {
                        final clickedDate = DateTime(
                          widget.selectedDate.year,
                          widget.selectedDate.month,
                          index + 1,
                        );
                        widget.onDateSelected(clickedDate);
                      } else if (_mode == 'yearly') {
                        final clickedDate = DateTime(
                          widget.selectedDate.year,
                          index + 1,
                          1,
                        );
                        widget.onDateSelected(clickedDate);
                      }
                    },
                    child: Container(
                      width: _mode == 'daily' ? 12 : 14,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
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
