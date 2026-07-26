import 'dart:io';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../providers/geotag_provider.dart';
import '../providers/settings_provider.dart';
import '../models/location_point.dart';

class GeotagScreen extends StatefulWidget {
  const GeotagScreen({super.key});

  @override
  State<GeotagScreen> createState() => _GeotagScreenState();
}

class _GeotagScreenState extends State<GeotagScreen> {
  final MapController _mapController = MapController();
  final LatLng _mapCenter =
      const LatLng(10.7790301, 106.6837685); // Default to Viettel Tower
  bool _tapToPin = false;
  String? _hoveredImagePath;
  bool _isTimelineChartExpanded = false;

  // Track previous states to detect transitions
  bool _wasMatching = false;
  bool _wasLoadingFiles = false;
  GeotagProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GeotagProvider>().loadTimelineLocationsFromAppDb();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = context.read<GeotagProvider>();
    if (p != _provider) {
      _provider?.removeListener(_onProviderChanged);
      _provider = p;
      _provider!.addListener(_onProviderChanged);
    }
  }

  void _onProviderChanged() {
    final nowMatching = _provider?.isMatching ?? false;
    final nowLoadingFiles = _provider?.isLoadingFiles ?? false;

    // Detect the moment matching finishes
    if (_wasMatching && !nowMatching) {
      final loc = _provider?.lastMatchedLocation;
      if (loc != null) {
        _mapController.move(LatLng(loc.latitude, loc.longitude), 13.0);
      }
    }

    // Detect the moment loading files finishes
    if (_wasLoadingFiles && !nowLoadingFiles) {
      if (_provider != null && _provider!.items.isNotEmpty) {
        _showToast(
          'Loaded ${_provider!.items.length} photos',
          icon: Icons.photo_library,
          color: Colors.blue,
        );
      }
    }

    _wasMatching = nowMatching;
    _wasLoadingFiles = nowLoadingFiles;
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  /// Show a modern bottom-right toast notification using Overlay.
  void _showToast(String message,
      {IconData icon = Icons.check_circle, Color color = Colors.green}) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        icon: icon,
        color: color,
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  void _showTimelineSegmentsDialog(
      BuildContext context, GeotagProvider provider) {
    final segments = provider.getTimelineSegments();
    final tz = provider.geotagTimezone;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.segment, color: Colors.blue),
            const SizedBox(width: 12),
            const Text('Timeline Activity Segments'),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Continuous periods with data (Max Gap: ${provider.maxInterpolationGapMinutes}m). Click segment to view points.',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: segments.length,
                  itemBuilder: (context, index) {
                    final s = segments[index];
                    final start = s['start']!.toUtc().add(Duration(hours: tz));
                    final end = s['end']!.toUtc().add(Duration(hours: tz));
                    final duration = end.difference(start);
                    final points = s['points'] as List<LocationPoint>;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withValues(alpha: 0.1)),
                      ),
                      child: ListTile(
                        dense: true,
                        onTap: () => _showPointsListDialog(
                            context, points, index + 1, tz),
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: Colors.blue.shade100,
                          child: Text('${index + 1}',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                        title: Text(
                          '${DateFormat('HH:mm').format(start)} – ${DateFormat('HH:mm').format(end)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${DateFormat('yyyy-MM-dd').format(start)} • ${duration.inHours}h ${duration.inMinutes % 60}m',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('${points.length}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue)),
                            const Text('pts', style: TextStyle(fontSize: 10)),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPointsListDialog(BuildContext context, List<LocationPoint> points,
      int segmentNum, int tz) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Segment #$segmentNum Points (${points.length})'),
        content: SizedBox(
          width: 500,
          height: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Click any point to locate it on the map.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: points.length,
                  itemBuilder: (context, index) {
                    final p = points[index];
                    final localTime =
                        p.timestamp.toUtc().add(Duration(hours: tz));
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(
                        '${DateFormat('HH:mm:ss').format(localTime)} — ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      onTap: () {
                        _mapController.move(p.latLng, 15.0);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        final files = detail.files.map((e) => File(e.path)).toList();
        context.read<GeotagProvider>().addFiles(files);
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 1,
              child: Column(
                children: [
                  _buildHeader(context),
                  const SizedBox(height: 16),
                  Expanded(child: _buildFileList(context)),
                  const SizedBox(height: 16),
                  _buildActionButtons(context),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: _buildMapPreview(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<GeotagProvider>();
    final isBusy = provider.isLoadingFiles;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Geotag Photos',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (provider.loadedTimelineFileName == null)
              Text('Add GPS data using Map or import Timeline JSON.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.grey[600]))
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Timeline: ${provider.loadedTimelineFileName}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.green, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: isBusy
                        ? null
                        : () {
                            context.read<GeotagProvider>().unloadTimeline();
                            _showToast('Timeline unloaded',
                                icon: Icons.link_off, color: Colors.orange);
                          },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 0),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text('Unload'),
                  ),
                ],
              ),
              if (provider.timelineLocations.isNotEmpty) ...[
                Tooltip(
                  message: 'Click to toggle GPS coverage chart',
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _isTimelineChartExpanded = !_isTimelineChartExpanded;
                      });
                    },
                    onLongPress: () =>
                        _showTimelineSegmentsDialog(context, provider),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${DateFormat('yyyy-MM-dd HH:mm').format(provider.timelineLocations.first.timestamp.toUtc().add(Duration(hours: provider.geotagTimezone)))}'
                            ' – '
                            '${DateFormat('yyyy-MM-dd HH:mm').format(provider.timelineLocations.last.timestamp.toUtc().add(Duration(hours: provider.geotagTimezone)))}'
                            ' (${provider.timelineLocations.length} pts)',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.blue[700],
                                      decoration: TextDecoration.underline,
                                      fontWeight: FontWeight.w500,
                                    ),
                          ),
                          Icon(
                            _isTimelineChartExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 14,
                            color: Colors.blue[700],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_isTimelineChartExpanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.analytics_outlined,
                                size: 14, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text('GPS Tracking Coverage (Pings)',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey[600])),
                            const Spacer(),
                            TextButton(
                              onPressed: () => _showTimelineSegmentsDialog(
                                  context, provider),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('View Segments',
                                  style: TextStyle(fontSize: 10)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TimelineMiniChart(
                          points: provider.timelineLocations,
                          maxGapMinutes: provider.maxInterpolationGapMinutes,
                          timezoneOffset: provider.geotagTimezone,
                        ),
                      ],
                    ),
                  ),
              ],
            ],
            // Loading-files progress
            if (isBusy) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.loadingMessage,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey[700]),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Stop Loading button
                  TextButton.icon(
                    onPressed: () =>
                        context.read<GeotagProvider>().cancelLoad(),
                    icon: const Icon(Icons.stop_circle_outlined,
                        size: 16, color: Colors.redAccent),
                    label: const Text('Stop',
                        style: TextStyle(color: Colors.redAccent)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 0),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: provider.totalFilesToLoad == 0
                    ? null
                    : provider.loadedFilesCount / provider.totalFilesToLoad,
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  onPressed: isBusy
                      ? null
                      : () async {
                          await context.read<GeotagProvider>().loadTimelineLocationsFromAppDb();
                          _showToast(
                            'Loaded from App Database',
                            icon: Icons.storage,
                            color: Colors.green,
                          );
                        },
                  icon: const Icon(Icons.storage),
                  tooltip: 'Load from App Database',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isBusy
                        ? null
                        : () async {
                            FilePickerResult? result =
                                await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['json'],
                            );
                            if (result != null &&
                                result.files.single.path != null) {
                              final file = File(result.files.single.path!);
                              final content = await file.readAsString();
                              if (context.mounted) {
                                context.read<GeotagProvider>().loadTimelineData(
                                    content, file.uri.pathSegments.last);
                                _showToast(
                                  'Timeline loaded — press "Match Location"',
                                  icon: Icons.timeline,
                                  color: Colors.green,
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.import_export),
                    label: const Text('Load Timeline'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isBusy
                        ? null
                        : () async {
                            FilePickerResult? result = await FilePicker.platform
                                .pickFiles(allowMultiple: true);
                            if (result != null) {
                              final files = result.paths
                                  .where((p) => p != null)
                                  .map((p) => File(p!))
                                  .toList();
                              if (context.mounted) {
                                context.read<GeotagProvider>().addFiles(files);
                              }
                            }
                          },
                    icon: isBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.add_photo_alternate),
                    label: Text(isBusy ? 'Loading…' : 'Add Photos'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(BuildContext context) {
    final provider = context.watch<GeotagProvider>();
    if (provider.items.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border:
              Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_library, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text('Drag photos here', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final list = Card(
      elevation: 2,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.grey.shade100,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => context.read<GeotagProvider>().checkAll(),
                  child: const Text('Check All'),
                ),
                TextButton(
                  onPressed: () => context.read<GeotagProvider>().uncheckAll(),
                  child: const Text('Uncheck All'),
                ),
                TextButton(
                  onPressed: () =>
                      context.read<GeotagProvider>().selectOnlyErrors(),
                  child: const Text('Errors Only'),
                ),
                TextButton(
                  onPressed: () =>
                      context.read<GeotagProvider>().uncheckSuccess(),
                  child: const Text('Uncheck Success'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: provider.items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = provider.items[index];

                // Format the photo's time for display using the selected display timezone
                String timeText = '';
                if (item.dateTaken != null) {
                  final displayTime = item.dateTaken!
                      .toUtc()
                      .add(Duration(hours: provider.geotagTimezone));
                  timeText = DateFormat('HH:mm:ss').format(displayTime);
                }

                String subtext = item.location != null
                    ? '${item.location!.latitude.toStringAsFixed(4)}, '
                        '${item.location!.longitude.toStringAsFixed(4)}'
                    : 'No location matched';
                if (item.errorMessage != null) subtext = item.errorMessage!;

                // Prepend the time to the subtext if available
                if (timeText.isNotEmpty) {
                  subtext = '[$timeText] $subtext';
                }

                Color subtextColor = Colors.red;
                IconData iconData = Icons.location_off;

                if (item.isSuccess) {
                  subtextColor = Colors.green;
                  iconData = Icons.check_circle;
                } else if (item.isError) {
                  // Pending-match items get a softer colour
                  final isPending =
                      item.errorMessage?.startsWith('Pending') == true ||
                          item.errorMessage?.contains('press Match') == true;
                  subtextColor =
                      isPending ? Colors.orange.shade700 : Colors.red;
                  iconData = isPending ? Icons.pending_outlined : Icons.error;
                } else if (item.hasExistingGps &&
                    !provider.overrideExistingGps) {
                  subtextColor = Colors.amber.shade700;
                  iconData = Icons.warning;
                } else if (item.location != null) {
                  if (item.hasExistingGps && provider.overrideExistingGps) {
                    subtextColor = Colors.deepPurple;
                    iconData = Icons.edit_location_alt;
                    if (item.errorMessage == null) {
                      subtext += ' (Will override)';
                    }
                  } else {
                    subtextColor = Colors.blue;
                    iconData = Icons.location_on;
                  }
                }

                return ListTile(
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: item.isChecked,
                        onChanged: (val) => context
                            .read<GeotagProvider>()
                            .toggleItemCheck(item, val ?? false),
                      ),
                      if (provider.showImagePreviews)
                        Container(
                          width: 48,
                          height: 48,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: Colors.grey.shade200,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.file(item.file,
                              fit: BoxFit.cover,
                              cacheWidth: 120,
                              errorBuilder: (c, o, s) => const Icon(
                                  Icons.broken_image,
                                  color: Colors.grey)),
                        ),
                      Icon(iconData, color: subtextColor),
                    ],
                  ),
                  title: Text(item.filename, overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text(subtext, style: TextStyle(color: subtextColor)),
                  onTap: () {
                    if (item.location != null) {
                      _mapController.move(
                          LatLng(item.location!.latitude,
                              item.location!.longitude),
                          15.0);
                    }
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.close, color: Colors.red),
                    onPressed: () =>
                        context.read<GeotagProvider>().removeFile(item),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    // Overlay a semi-transparent progress shield while matching
    if (!provider.isMatching) return list;

    return Stack(
      children: [
        list,
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  provider.loadingMessage,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: LinearProgressIndicator(
                    value: provider.totalToMatch == 0
                        ? null
                        : provider.matchedCount / provider.totalToMatch,
                    backgroundColor: Colors.white30,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.lightBlueAccent),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${provider.matchedCount} / ${provider.totalToMatch}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMapPreview(BuildContext context) {
    final provider = context.watch<GeotagProvider>();

    List<Marker> markers = [];

    // Create markers for items
    for (var item in provider.items) {
      if (item.location != null) {
        markers.add(Marker(
          point: LatLng(item.location!.latitude, item.location!.longitude),
          width: 14,
          height: 14,
          child: Container(
            decoration: BoxDecoration(
              color: Color.fromARGB(255, 148, 181, 254),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 3)
              ],
            ),
          ),
        ));
      }
    }

    // Create markers for history
    for (var history in provider.historyMarkers) {
      markers.add(Marker(
        point: LatLng(history.latitude, history.longitude),
        width: history.isManual ? 36 : 12,
        height: history.isManual ? 36 : 12,
        child: _buildHistoryMarker(history),
      ));
    }

    // Current override marker logic removed - manual overrides update selected items instead

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          _buildMapWidget(context, markers),
          if (!_tapToPin)
            IgnorePointer(
              child: Center(
                child: Icon(
                  Icons.add,
                  size: 32,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                        color: Colors.black.withValues(alpha: 0.8),
                        offset: const Offset(1, 1)),
                    Shadow(
                        color: Colors.black.withValues(alpha: 0.8),
                        offset: const Offset(-1, -1)),
                    Shadow(
                        color: Colors.black.withValues(alpha: 0.8),
                        offset: const Offset(1, -1)),
                    Shadow(
                        color: Colors.black.withValues(alpha: 0.8),
                        offset: const Offset(-1, 1)),
                  ],
                ), // Crosshair
              ),
            ),
          Positioned(
            top: 16,
            left: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: context.watch<SettingsProvider>().mapProvider,
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
                        onChanged: (val) {
                          if (val != null) {
                            context
                                .read<SettingsProvider>()
                                .updateMapProvider(val);
                          }
                        },
                      ),
                    ),
                  ),
                ),
                if (_hoveredImagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Card(
                      elevation: 8,
                      clipBehavior: Clip.antiAlias,
                      child: Container(
                        width: 200,
                        height: 150,
                        decoration: BoxDecoration(
                          image: DecorationImage(
                            image: FileImage(File(_hoveredImagePath!)),
                            fit: BoxFit.cover,
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            color: Colors.black54,
                            padding: const EdgeInsets.all(4),
                            child: Text(
                              _hoveredImagePath!
                                  .split(Platform.pathSeparator)
                                  .last,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!_tapToPin)
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton.extended(
                onPressed: () {
                  final center = _mapController.camera.center;
                  context.read<GeotagProvider>().setCurrentLocationOverride(
                      center.latitude, center.longitude);
                },
                icon: const Icon(Icons.pin_drop),
                label: const Text('Pin Center'),
              ),
            ),
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding:
                  const EdgeInsets.only(left: 8, right: 12, top: 4, bottom: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4)
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _tapToPin,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => _tapToPin = v ?? false),
                  ),
                  const Text('Tap to pin',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapWidget(BuildContext context, List<Marker> markers) {
    final map = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _mapCenter,
        initialZoom: 13.0,
        interactionOptions: InteractionOptions(
          flags: _tapToPin
              ? InteractiveFlag.all
              : (InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom),
        ),
        onTap: (tapPosition, point) {
          if (_tapToPin) {
            context
                .read<GeotagProvider>()
                .setCurrentLocationOverride(point.latitude, point.longitude);
          }
        },
      ),
      children: [
        _buildTileLayer(context),
        MarkerLayer(markers: markers),
      ],
    );

    if (_tapToPin) {
      return map;
    }

    return Listener(
      onPointerSignal: (pointerSignal) {
        if (pointerSignal is PointerScrollEvent) {
          final zoomDelta = -pointerSignal.scrollDelta.dy / 500;
          final newZoom =
              (_mapController.camera.zoom + zoomDelta).clamp(1.0, 20.0);
          _mapController.move(_mapController.camera.center, newZoom);
        }
      },
      child: map,
    );
  }

  Widget _buildTileLayer(BuildContext context) {
    final mapProvider = context.watch<SettingsProvider>().mapProvider;

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

  Widget _buildActionButtons(BuildContext context) {
    final provider = context.watch<GeotagProvider>();
    final isBusy =
        provider.isProcessing || provider.isMatching || provider.isLoadingFiles;

    // A compact checkbox+label pair that never gets separated
    Widget checkRow({
      required bool value,
      required String label,
      required ValueChanged<bool?>? onChanged,
    }) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            onChanged: onChanged,
          ),
          Text(label),
          const SizedBox(width: 4),
        ],
      );
    }

    return SingleChildScrollView(
      // Scrolls vertically if the panel is too short
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Settings row (wraps onto next line if needed) ──────────────
          Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              // Max Gap label + dropdown (kept together as a Row)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Max Gap:'),
                  const SizedBox(width: 4),
                  DropdownButton<int>(
                    value: provider.maxInterpolationGapMinutes,
                    isDense: true,
                    items: [30, 60, 120, 240, 480, 720]
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text('${e}m')))
                        .toList(),
                    onChanged: isBusy
                        ? null
                        : (val) {
                            if (val != null) {
                              context
                                  .read<GeotagProvider>()
                                  .setMaxInterpolationGapMinutes(val);
                            }
                          },
                  ),
                ],
              ),
              // Timezone dropdown (Unified Timezone & Matching Offset)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Default Timezone:'),
                  const SizedBox(width: 4),
                  DropdownButton<int>(
                    value: provider.geotagTimezone,
                    isDense: true,
                    items: List.generate(29, (i) => i - 14)
                        .map((e) => DropdownMenuItem(
                            value: e, child: Text(e >= 0 ? 'UTC+$e' : 'UTC$e')))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        context.read<GeotagProvider>().setTimezone(val);
                        // Also sync with global settings
                        context
                            .read<SettingsProvider>()
                            .updateGeotagTimezone(val);
                      }
                    },
                  ),
                ],
              ),
              // Checkbox rows — each is an atomic Row that wraps as one unit
              checkRow(
                value: provider.overrideExistingGps,
                label: 'Override existing',
                onChanged: isBusy
                    ? null
                    : (val) => context
                        .read<GeotagProvider>()
                        .setOverrideExistingGps(val ?? false),
              ),
              checkRow(
                value: provider.autoClearList,
                label: 'Auto clear',
                onChanged: isBusy
                    ? null
                    : (val) => context
                        .read<GeotagProvider>()
                        .setAutoClearList(val ?? false),
              ),
              checkRow(
                value: provider.showImagePreviews,
                label: 'Show Previews',
                onChanged: isBusy
                    ? null
                    : (val) => context
                        .read<GeotagProvider>()
                        .setShowImagePreviews(val ?? false),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Match-location progress bar ─────────────────────────────────
          if (provider.isMatching) ...[
            Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    provider.loadingMessage,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey[700]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${provider.matchedCount} / ${provider.totalToMatch}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey[700]),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: provider.totalToMatch == 0
                  ? null
                  : provider.matchedCount / provider.totalToMatch,
            ),
            const SizedBox(height: 8),
          ],

          // ── Action buttons ──────────────────────────────────────────────
          // Use a Wrap so the buttons themselves also reflow instead of overflow
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: isBusy || provider.items.isEmpty
                    ? null
                    : () => context.read<GeotagProvider>().clearFiles(),
                child: const Text('Clear List'),
              ),
              // While matching: show Stop button too
              if (provider.isMatching)
                OutlinedButton.icon(
                  onPressed: () => context.read<GeotagProvider>().cancelMatch(),
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.redAccent),
                  label: const Text('Stop',
                      style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent)),
                ),
              OutlinedButton.icon(
                onPressed: isBusy || provider.items.isEmpty
                    ? null
                    : () => context.read<GeotagProvider>().matchLocations(),
                icon: provider.isMatching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location),
                label:
                    Text(provider.isMatching ? 'Matching…' : 'Match Location'),
              ),
              FilledButton.icon(
                onPressed: isBusy || provider.items.isEmpty
                    ? null
                    : () => context.read<GeotagProvider>().applyChanges(),
                icon: provider.isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save),
                label: Text(provider.isProcessing
                    ? 'Processing '
                        '${provider.currentProcessing}/${provider.totalProcessing}'
                    : 'Apply Geotags'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryMarker(TaggedHistoryItem history) {
    if (history.isManual) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)
          ],
        ),
        child: ClipOval(
          child: Image.file(
            File(history.path),
            fit: BoxFit.cover,
            cacheWidth: 120,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image, size: 20),
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredImagePath = history.path),
      onExit: (_) => setState(() => _hoveredImagePath = null),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: const Color.fromARGB(255, 225, 225, 225),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 2)
          ],
        ),
      ),
    );
  }
}

class TimelineMiniChart extends StatefulWidget {
  final List<LocationPoint> points;
  final int maxGapMinutes;
  final int timezoneOffset;

  const TimelineMiniChart({
    super.key,
    required this.points,
    required this.maxGapMinutes,
    required this.timezoneOffset,
  });

  @override
  State<TimelineMiniChart> createState() => _TimelineMiniChartState();
}

class _TimelineMiniChartState extends State<TimelineMiniChart> {
  double? _hoverX;

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) return const SizedBox.shrink();

    return MouseRegion(
      onHover: (event) {
        setState(() {
          _hoverX = event.localPosition.dx;
        });
      },
      onExit: (_) {
        setState(() {
          _hoverX = null;
        });
      },
      child: Container(
        height: 48, // Increased height for hover label
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.blue.withValues(alpha: 0.08)),
        ),
        child: CustomPaint(
          painter: _TimelineChartPainter(
            widget.points,
            widget.maxGapMinutes,
            widget.timezoneOffset,
            _hoverX,
          ),
        ),
      ),
    );
  }
}

class _TimelineChartPainter extends CustomPainter {
  final List<LocationPoint> points;
  final int maxGapMinutes;
  final int timezoneOffset;
  final double? hoverX;

  _TimelineChartPainter(
      this.points, this.maxGapMinutes, this.timezoneOffset, this.hoverX);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final startMs = points.first.timestamp.millisecondsSinceEpoch;
    final endMs = points.last.timestamp.millisecondsSinceEpoch;
    final durationMs = endMs - startMs;
    if (durationMs == 0) return;

    final int bucketCount = size.width.toInt().clamp(100, 1000);
    final double bucketWidth = size.width / bucketCount;
    final List<double> buckets = List.filled(bucketCount, 0.0);

    for (var p in points) {
      double t = (p.timestamp.millisecondsSinceEpoch - startMs) / durationMs;
      int idx = (t * (bucketCount - 1)).toInt().clamp(0, bucketCount - 1);
      buckets[idx] += 1.0;
    }

    final path = ui.Path();
    final fillPath = ui.Path();

    const double chartTop = 15.0; // Margin for hover label

    path.moveTo(0, size.height);
    fillPath.moveTo(0, size.height);

    for (int i = 0; i < bucketCount; i++) {
      final x = i * bucketWidth;
      double h = buckets[i] > 0 ? chartTop + 4.0 : size.height - 2.0;

      path.lineTo(x, h);
      fillPath.lineTo(x, h);
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, chartTop),
        Offset(0, size.height),
        [Colors.blue.withValues(alpha: 0.3), Colors.blue.withValues(alpha: 0.01)],
      )
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = Colors.blue.shade400
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    // Hover seeker and time label
    if (hoverX != null && hoverX! >= 0 && hoverX! <= size.width) {
      final seekerPaint = Paint()
        ..color = Colors.orange.withValues(alpha: 0.8)
        ..strokeWidth = 1.0;
      canvas.drawLine(
          Offset(hoverX!, chartTop), Offset(hoverX!, size.height), seekerPaint);

      // Calculate time at hover position
      final double ratio = hoverX! / size.width;
      final int targetMs = startMs + (durationMs * ratio).toInt();
      final DateTime hoverTime =
          DateTime.fromMillisecondsSinceEpoch(targetMs, isUtc: true)
              .add(Duration(hours: timezoneOffset));

      final timeText = DateFormat('HH:mm:ss').format(hoverTime);
      final tp = TextPainter(
        text: TextSpan(
          text: timeText,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.orange,
            backgroundColor: Colors.white70,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      tp.layout();

      // Keep label within bounds
      double labelX = hoverX! - tp.width / 2;
      if (labelX < 0) labelX = 0;
      if (labelX + tp.width > size.width) labelX = size.width - tp.width;

      tp.paint(canvas, Offset(labelX, 2));
    }

    _drawLabel(canvas, size, "Start", 0);
    _drawLabel(canvas, size, "End", size.width - 25);
  }

  void _drawLabel(Canvas canvas, Size size, String text, double x) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 8, color: Colors.grey[500]),
      ),
      textDirection: ui.TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(x, size.height - tp.height));
  }

  @override
  bool shouldRepaint(covariant _TimelineChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.hoverX != hoverX;
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.icon,
    required this.color,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _controller.forward();

    // Auto dismiss after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _controller.reverse().then((_) => widget.onDismiss());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[900]?.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: widget.color, size: 20),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
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
