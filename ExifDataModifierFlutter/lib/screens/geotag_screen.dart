import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../providers/geotag_provider.dart';

class GeotagScreen extends StatefulWidget {
  const GeotagScreen({super.key});

  @override
  State<GeotagScreen> createState() => _GeotagScreenState();
}

class _GeotagScreenState extends State<GeotagScreen> {
  final MapController _mapController = MapController();
  LatLng _mapCenter = const LatLng(21.0285, 105.8542); // Default to Hanoi

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
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Geotag Photos', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Add GPS data using Map or import Timeline JSON.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null && result.files.single.path != null) {
                        final file = File(result.files.single.path!);
                        final content = await file.readAsString();
                        if (context.mounted) {
                          context.read<GeotagProvider>().loadTimelineData(content);
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
                      FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
                      if (result != null) {
                        final files = result.paths.where((p) => p != null).map((p) => File(p!)).toList();
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
          border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
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
      child: ListView.separated(
        itemCount: provider.items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = provider.items[index];
          String subtext = item.location != null
              ? '${item.location!.latitude.toStringAsFixed(4)}, ${item.location!.longitude.toStringAsFixed(4)}'
              : 'No location matched';
          Color subtextColor = item.isSuccess ? Colors.green : (item.location != null ? Colors.blue : Colors.red);

          return ListTile(
            leading: Icon(
              item.isSuccess ? Icons.check_circle : (item.location != null ? Icons.location_on : Icons.location_off),
              color: item.isSuccess ? Colors.green : (item.location != null ? Colors.blue : Colors.red),
            ),
            title: Text(item.filename, overflow: TextOverflow.ellipsis),
            subtitle: Text(subtext, style: TextStyle(color: subtextColor)),
            onTap: () {
              if (item.location != null) {
                _mapController.move(LatLng(item.location!.latitude, item.location!.longitude), 15.0);
              }
            },
            trailing: IconButton(
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => context.read<GeotagProvider>().removeFile(item),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMapPreview(BuildContext context) {
    final provider = context.watch<GeotagProvider>();
    
    List<Marker> markers = [];
    
    // Create markers for items
    for (var item in provider.items) {
      if (item.location != null) {
        markers.add(
          Marker(
            point: LatLng(item.location!.latitude, item.location!.longitude),
            width: 40,
            height: 40,
            child: const Icon(Icons.location_on, color: Colors.red, size: 40),
          )
        );
      }
    }
    
    // Current override marker
    if (provider.currentLocationOverride != null) {
        markers.add(
          Marker(
            point: LatLng(provider.currentLocationOverride!.latitude, provider.currentLocationOverride!.longitude),
            width: 40,
            height: 40,
            child: const Icon(Icons.my_location, color: Colors.blue, size: 40),
          )
        );
    }

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
                context.read<GeotagProvider>().setCurrentLocationOverride(point.latitude, point.longitude);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.exifmodifier',
              ),
              MarkerLayer(markers: markers),
            ],
          ),
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4)],
              ),
              child: const Text('Tap map to select location manually', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final provider = context.watch<GeotagProvider>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: provider.items.isEmpty || provider.isProcessing ? null : () => context.read<GeotagProvider>().clearFiles(),
          child: const Text('Clear List'),
        ),
        const SizedBox(width: 16),
        FilledButton.icon(
          onPressed: provider.items.isEmpty || provider.isProcessing ? null : () => context.read<GeotagProvider>().applyChanges(),
          icon: provider.isProcessing 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
              : const Icon(Icons.save),
          label: Text(provider.isProcessing ? 'Processing...' : 'Apply Geotags'),
        ),
      ],
    );
  }
}
