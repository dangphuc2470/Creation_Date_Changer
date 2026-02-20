import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../models/location_point.dart';
import '../models/export_config.dart';
import '../services/timeline_parser.dart';
import '../services/gpx_parser.dart';
import '../services/export_service.dart';

class ImportExportScreen extends StatefulWidget {
  const ImportExportScreen({super.key});

  @override
  State<ImportExportScreen> createState() => _ImportExportScreenState();
}

class _ImportExportScreenState extends State<ImportExportScreen> {
  List<LocationPoint> _loadedPoints = [];
  bool _isLoading = false;
  String _statusMessage = 'No data loaded';
  double _progress = 0.0;
  
  ExportMode _exportMode = ExportMode.yearMonthDay;
  DateTime? _startDate;
  DateTime _endDate = DateTime.now();
  String? _outputPath;

  Future<void> _pickTimelineFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _isLoading = true;
        _statusMessage = 'Parsing Timeline.json...';
        _progress = 0.0;
      });

      try {
        final points = await TimelineParser.parseFile(
          filePath: result.files.single.path!,
          startDate: _startDate,
          endDate: _endDate,
          onProgress: (progress) {
            setState(() {
              _progress = progress.progress;
              _statusMessage = progress.message;
            });
          },
        );

        setState(() {
          _loadedPoints.addAll(points);
          _isLoading = false;
          _statusMessage = 'Loaded ${points.length} points from Timeline.json';
        });
      } catch (e) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _pickGpxFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gpx'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _isLoading = true;
        _statusMessage = 'Parsing GPX file...';
      });

      try {
        final points = await GpxParser.parseFile(result.files.single.path!);
        setState(() {
          _loadedPoints.addAll(points);
          _isLoading = false;
          _statusMessage = 'Loaded ${points.length} points from GPX';
        });
      } catch (e) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _pickOutputFolder() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _outputPath = result;
      });
    }
  }

  Future<void> _export() async {
    if (_loadedPoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to export')),
      );
      return;
    }

    if (_outputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select output folder')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Exporting...';
      _progress = 0.0;
    });

    try {
      final config = ExportConfig(
        mode: _exportMode,
        startDate: _startDate,
        endDate: _endDate,
        outputPath: _outputPath!,
      );

      final result = await ExportService.export(
        points: _loadedPoints,
        config: config,
        onProgress: (progress, message) {
          setState(() {
            _progress = progress;
            _statusMessage = message;
          });
        },
      );

      setState(() {
        _isLoading = false;
        _statusMessage = 'Exported ${result.pointsExported} points to ${result.filesCreated} files';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export complete: ${result.filesCreated} files created')),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Export error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Import Data', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _pickTimelineFile,
                          icon: const Icon(Icons.file_upload),
                          label: const Text('Import Timeline.json'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _pickGpxFile,
                          icon: const Icon(Icons.file_upload),
                          label: const Text('Import GPX'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Time Filter', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          title: Text(_startDate == null ? 'Start: All' : 'Start: ${DateFormat('yyyy-MM-dd').format(_startDate!)}'),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: _startDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now(),
                            );
                            if (date != null) {
                              setState(() => _startDate = date);
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: ListTile(
                          title: Text('End: ${DateFormat('yyyy-MM-dd').format(_endDate)}'),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: _endDate,
                              firstDate: _startDate ?? DateTime(2000),
                              lastDate: DateTime.now(),
                            );
                            if (date != null) {
                              setState(() => _endDate = date);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Export Settings', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  SegmentedButton<ExportMode>(
                    segments: const [
                      ButtonSegment(
                        value: ExportMode.yearMonthDay,
                        label: Text('Year/Month/Day'),
                        icon: Icon(Icons.folder_open),
                      ),
                      ButtonSegment(
                        value: ExportMode.dateRange,
                        label: Text('Date Range'),
                        icon: Icon(Icons.date_range),
                      ),
                    ],
                    selected: {_exportMode},
                    onSelectionChanged: (Set<ExportMode> newSelection) {
                      setState(() {
                        _exportMode = newSelection.first;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: Text(_outputPath ?? 'No output folder selected'),
                    subtitle: const Text('Output folder'),
                    trailing: const Icon(Icons.folder),
                    onTap: _pickOutputFolder,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : _export,
                    icon: const Icon(Icons.save),
                    label: const Text('Export'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_isLoading)
            LinearProgressIndicator(value: _progress),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_statusMessage),
                  const SizedBox(height: 8),
                  Text('Loaded points: ${_loadedPoints.length}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
