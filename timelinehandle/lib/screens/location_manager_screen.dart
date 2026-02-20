import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../services/location_manager.dart';

class LocationManagerScreen extends StatefulWidget {
  const LocationManagerScreen({super.key});

  @override
  State<LocationManagerScreen> createState() => _LocationManagerScreenState();
}

class _LocationManagerScreenState extends State<LocationManagerScreen> {
  List<DateInfo> _dates = [];
  bool _isLoading = false;
  String? _loadedPath;

  Future<void> _loadExportedData() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _isLoading = true;
        _loadedPath = result;
      });

      try {
        final dates = await LocationManager.scanExportedData(result);
        setState(() {
          _dates = dates;
          _isLoading = false;
        });
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error loading data: $e')),
          );
        }
      }
    }
  }

  Future<void> _viewOnMap(DateInfo dateInfo) async {
    try {
      final points = await LocationManager.loadLocationFile(dateInfo.filePath);
      if (mounted) {
        // TODO: Navigate to map viewer with these points
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Loaded ${points.length} points for ${DateFormat('yyyy-MM-dd').format(dateInfo.date)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading points: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _loadExportedData,
                icon: const Icon(Icons.folder_open),
                label: const Text('Load Exported Data'),
              ),
              if (_loadedPath != null) ...[
                const SizedBox(height: 8),
                Text('Loaded from: $_loadedPath', style: Theme.of(context).textTheme.bodySmall),
                Text('${_dates.length} dates found', style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_dates.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No data loaded. Click "Load Exported Data" to begin.'),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _dates.length,
              itemBuilder: (context, index) {
                final dateInfo = _dates[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.location_on),
                    title: Text(DateFormat('yyyy-MM-dd').format(dateInfo.date)),
                    subtitle: Text('${dateInfo.pointCount} location points'),
                    trailing: IconButton(
                      icon: const Icon(Icons.map),
                      onPressed: () => _viewOnMap(dateInfo),
                    ),
                    onTap: () => _viewOnMap(dateInfo),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
