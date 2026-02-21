import 'dart:io';
import 'package:intl/intl.dart';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../providers/geotag_provider.dart';
import '../providers/settings_provider.dart';

class GeotagScreen extends StatefulWidget {
  const GeotagScreen({super.key});

  @override
  State<GeotagScreen> createState() => _GeotagScreenState();
}

class _GeotagScreenState extends State<GeotagScreen> {
  final MapController _mapController = MapController();
  LatLng _mapCenter = const LatLng(10, 109); // Default to Hanoi
  bool _tapToPin = false;

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
              Text('Timeline loaded: ${provider.loadedTimelineFileName}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.green, fontWeight: FontWeight.bold)),
              if (provider.timelineLocations.isNotEmpty)
                Text(
                  'Data from: ${DateFormat('yyyy-MM-dd HH:mm').format(provider.timelineLocations.first.timestamp)} to ${DateFormat('yyyy-MM-dd HH:mm').format(provider.timelineLocations.last.timestamp)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey[600]),
                ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      FilePickerResult? result =
                          await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null && result.files.single.path != null) {
                        final file = File(result.files.single.path!);
                        final content = await file.readAsString();
                        if (context.mounted) {
                          context.read<GeotagProvider>().loadTimelineData(
                              content, file.uri.pathSegments.last);
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
                    onPressed: () async {
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
                    icon: const Icon(Icons.add_photo_alternate),
                    label: const Text('Add Photos'),
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

    return Card(
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
                String subtext = item.location != null
                    ? '${item.location!.latitude.toStringAsFixed(4)}, ${item.location!.longitude.toStringAsFixed(4)}'
                    : 'No location matched';
                if (item.errorMessage != null) {
                  subtext = item.errorMessage!;
                }

                Color subtextColor = Colors.red;
                IconData iconData = Icons.location_off;

                if (item.isSuccess) {
                  subtextColor = Colors.green;
                  iconData = Icons.check_circle;
                } else if (item.isError) {
                  subtextColor = Colors.red;
                  iconData = Icons.error;
                } else if (item.hasExistingGps &&
                    !provider.overrideExistingGps) {
                  subtextColor = Colors.amber.shade700;
                  iconData = Icons.warning;
                } else if (item.location != null) {
                  if (item.hasExistingGps && provider.overrideExistingGps) {
                    subtextColor = Colors.deepPurple;
                    iconData = Icons.edit_location_alt;
                    if (item.errorMessage == null)
                      subtext += ' (Will override)';
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
  }

  Widget _buildMapPreview(BuildContext context) {
    final provider = context.watch<GeotagProvider>();

    List<Marker> markers = [];

    // Create markers for items
    for (var item in provider.items) {
      if (item.location != null) {
        markers.add(Marker(
          point: LatLng(item.location!.latitude, item.location!.longitude),
          width: 40,
          height: 40,
          child: const Icon(Icons.location_on, color: Colors.blue, size: 40),
        ));
      }
    }

    // Create markers for history
    for (var history in provider.historyMarkers) {
      markers.add(Marker(
        point: LatLng(history.latitude, history.longitude),
        width: 36,
        height: 36,
        child: _buildHistoryMarker(history.path),
      ));
    }

    // Current override marker logic removed - manual overrides update selected items instead

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: 13.0,
              onTap: (tapPosition, point) {
                if (_tapToPin) {
                  context.read<GeotagProvider>().setCurrentLocationOverride(
                      point.latitude, point.longitude);
                }
              },
            ),
            children: [
              _buildTileLayer(context),
              MarkerLayer(markers: markers),
            ],
          ),
          if (!_tapToPin)
            const Center(
              child: Icon(Icons.add, size: 32, color: Colors.blue), // Crosshair
            ),
          Positioned(
            top: 16,
            left: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: context.watch<SettingsProvider>().mapProvider,
                    items: const [
                      DropdownMenuItem(
                          value: 'google_roadmap', child: Text('Google Maps')),
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
                        context.read<SettingsProvider>().updateMapProvider(val);
                      }
                    },
                  ),
                ),
              ),
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
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4)
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
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const Text('Max Gap:'),
            DropdownButton<int>(
              value: provider.maxInterpolationGapMinutes,
              isDense: true,
              items: [30, 60, 120, 240, 480, 720]
                  .map((e) => DropdownMenuItem(value: e, child: Text('${e}m')))
                  .toList(),
              onChanged: (val) {
                if (val != null)
                  context
                      .read<GeotagProvider>()
                      .setMaxInterpolationGapMinutes(val);
              },
            ),
            Checkbox(
              value: provider.overrideExistingGps,
              onChanged: (val) => context
                  .read<GeotagProvider>()
                  .setOverrideExistingGps(val ?? false),
            ),
            const Text('Override existing'),
            Checkbox(
              value: provider.autoClearList,
              onChanged: (val) =>
                  context.read<GeotagProvider>().setAutoClearList(val ?? false),
            ),
            const Text('Auto clear'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: provider.items.isEmpty || provider.isProcessing
                  ? null
                  : () => context.read<GeotagProvider>().clearFiles(),
              child: const Text('Clear List'),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: provider.items.isEmpty || provider.isProcessing
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
                  ? 'Processing ${provider.currentProcessing}/${provider.totalProcessing}'
                  : 'Apply Geotags'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHistoryMarker(String path) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: ClipOval(
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.broken_image, size: 20),
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
