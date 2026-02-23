import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import '../models/location_point.dart';
import '../services/map_service.dart';
import '../services/settings_service.dart';

class MapViewerScreen extends StatefulWidget {
  final Map<String, List<LocationPoint>> paths;
  final Map<String, Color> pathColors;

  const MapViewerScreen({
    super.key,
    required this.paths,
    required this.pathColors,
  });

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> {
  final MapController _mapController = MapController();
  MapType _currentMapType = MapType.openStreetMap;
  bool _isLoadingMapSettings = true;
  double _timeOffset = 0.0;

  // Hover state
  LocationPoint? _hoveredPoint;
  Color? _hoveredColor;
  LatLng? _hoveredLatLng;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    if (widget.paths.isNotEmpty) {
      _fitBounds();
    }
  }

  Future<void> _loadSettings() async {
    final type = await MapService.getMapType();
    final offset = await SettingsService.getTimezoneOffset();
    setState(() {
      _currentMapType = type;
      _timeOffset = offset;
      _isLoadingMapSettings = false;
    });
  }

  @override
  void didUpdateWidget(MapViewerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paths.length != oldWidget.paths.length &&
        widget.paths.isNotEmpty) {
      _fitBounds();
    }
    // Refresh settings whenever widget updates (in case parent notified us)
    _loadSettings();
  }

  void _fitBounds() {
    if (widget.paths.isEmpty) return;

    final allPoints = widget.paths.values
        .expand((points) => points.map((p) => p.latLng))
        .toList();
    if (allPoints.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(allPoints);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50.0),
        ),
      );
    });
  }

  String _getTileUrl(MapType type) {
    switch (type) {
      case MapType.googleNormal:
        return 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
      case MapType.googleSatellite:
        return 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}';
      case MapType.openStreetMap:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }
  }

  void _handleHover(PointerHoverEvent event, LatLng point) {
    if (widget.paths.isEmpty) return;

    LocationPoint? closestPoint;
    Color? closestColor;
    double minDistance = double.infinity;
    const double snapThreshold = 0.005;

    for (final entry in widget.paths.entries) {
      final color = widget.pathColors[entry.key] ?? Colors.blue;
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
  }

  @override
  Widget build(BuildContext context) {
    if (widget.paths.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No Paths Selected',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Select dates from Location Manager to view on map'),
          ],
        ),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: widget.paths.values.first.first.latLng,
            initialZoom: 13,
            onPointerHover: _handleHover,
          ),
          children: [
            if (!_isLoadingMapSettings)
              TileLayer(
                urlTemplate: _getTileUrl(_currentMapType),
                userAgentPackageName: 'com.example.timelinehandle',
              ),
            PolylineLayer(
              polylines: widget.paths.entries.map((entry) {
                return Polyline(
                  points: entry.value.map((p) => p.latLng).toList(),
                  strokeWidth: 4,
                  color: widget.pathColors[entry.key] ?? Colors.blue,
                );
              }).toList(),
            ),
            if (_hoveredPoint != null && _hoveredLatLng != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _hoveredLatLng!,
                    width: 200,
                    height: 120,
                    alignment: Alignment
                        .center, // Center the whole marker on the point
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // Dot exactly on point
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: _hoveredColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: [
                              BoxShadow(color: Colors.black38, blurRadius: 6),
                            ],
                          ),
                        ),
                        // Tooltip positioned clearly ABOVE the center point
                        Positioned(
                          bottom: 75,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 4,
                                    offset: Offset(0, 2)),
                              ],
                            ),
                            child: Builder(builder: (context) {
                              final displayTime = _hoveredPoint!.timestamp.add(
                                Duration(minutes: (_timeOffset * 60).toInt()),
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
        // Map Controls
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withOpacity(0.9),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: DropdownButton<MapType>(
              value: _currentMapType,
              underline: const SizedBox(),
              onChanged: (MapType? newValue) {
                if (newValue != null) {
                  setState(() => _currentMapType = newValue);
                  MapService.setMapType(newValue);
                }
              },
              items: MapType.values.map((MapType type) {
                return DropdownMenuItem<MapType>(
                  value: type,
                  child: Text(MapService.getMapTypeName(type)),
                );
              }).toList(),
            ),
          ),
        ),
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
        // Selection Info
        Positioned(
          bottom: 16,
          right: 16,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Legend (${widget.paths.length} paths)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  ...widget.paths.keys.map((key) {
                    final color = widget.pathColors[key] ?? Colors.blue;
                    final fileName = key.split('\\').last;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          Container(width: 12, height: 12, color: color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              fileName,
                              style: const TextStyle(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
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
    );
  }
}
