import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../services/location_manager.dart';
import '../models/location_point.dart';

class LocationManagerScreen extends StatefulWidget {
  final List<DateInfo> dates;
  final String? loadedPath;
  final Function(List<DateInfo>, String) onDatesLoaded;
  final Set<String> activePathIds;
  final Function(DateInfo, List<LocationPoint>) onTogglePath;

  const LocationManagerScreen({
    super.key,
    required this.dates,
    required this.loadedPath,
    required this.onDatesLoaded,
    required this.activePathIds,
    required this.onTogglePath,
  });

  @override
  State<LocationManagerScreen> createState() => _LocationManagerScreenState();
}

class _LocationManagerScreenState extends State<LocationManagerScreen> {
  bool _isLoading = false;

  Future<void> _loadExportedData() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _isLoading = true;
      });

      try {
        final dates = await LocationManager.scanExportedData(result);
        widget.onDatesLoaded(dates, result);
        setState(() {
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
        widget.onTogglePath(dateInfo, points);
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
              if (widget.loadedPath != null) ...[
                const SizedBox(height: 8),
                Text('Loaded from: ${widget.loadedPath}',
                    style: Theme.of(context).textTheme.bodySmall),
                Text('${widget.dates.length} dates found',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (widget.dates.isEmpty)
          const Expanded(
            child: Center(
              child:
                  Text('No data loaded. Click "Load Exported Data" to begin.'),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: widget.dates.length,
              itemBuilder: (context, index) {
                final dateInfo = widget.dates[index];
                final isActive =
                    widget.activePathIds.contains(dateInfo.filePath);

                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  elevation: isActive ? 4 : 1,
                  shape: isActive
                      ? RoundedRectangleBorder(
                          side: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isActive
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      child: Icon(
                        isActive ? Icons.check : Icons.location_on,
                        color: isActive ? Colors.white : null,
                      ),
                    ),
                    title: Text(DateFormat('yyyy-MM-dd').format(dateInfo.date)),
                    subtitle: Text('${dateInfo.pointCount} location points'),
                    trailing: TextButton(
                      onPressed: () => _viewOnMap(dateInfo),
                      child: Text(isActive ? 'SELECTED' : 'VIEW'),
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
