import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/location_point.dart';
import '../models/export_config.dart';
import '../services/timeline_parser.dart';
import '../services/gpx_parser.dart';
import '../services/export_service.dart';
import '../services/batch_import_service.dart';
import 'conflict_resolver_screen.dart';
import '../providers/settings_provider.dart';
import '../providers/app_state_provider.dart';
import '../services/location_manager.dart';
import '../providers/geotag_provider.dart';
import '../providers/batch_geotag_provider.dart';
import 'package:path/path.dart' as path;

class ImportExportScreen extends StatefulWidget {
  const ImportExportScreen({super.key});

  @override
  State<ImportExportScreen> createState() => _ImportExportScreenState();
}

class _ImportExportScreenState extends State<ImportExportScreen> {
  int _lastImportedCount = 0;
  bool _isLoading = false;
  String _statusMessage = 'No active imports';
  double _progress = 0.0;

  ExportMode _exportMode = ExportMode.dailyFiles;
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
            if (mounted) {
              setState(() {
                _progress = progress.progress;
                _statusMessage = progress.message;
              });
            }
          },
        );

        if (!mounted) return;

        if (points.isNotEmpty) {
          final appState = context.read<AppStateProvider>();
          await appState.saveImportedPoints(points, 'timeline');
          
          if (!mounted) return;

          // Reload geotag providers with the new points
          context.read<GeotagProvider>().loadTimelineLocationsFromAppDb();
          context.read<BatchGeotagProvider>().loadTimelineLocationsFromAppDb();

          // Auto switch to MapViewerScreen tab (Index 5)
          appState.setIndex(5);

          setState(() {
            _lastImportedCount = points.length;
            _isLoading = false;
            _statusMessage = 'Successfully imported ${points.length} points to App Database!';
            if (_outputPath == null) {
              final parentDir = path.dirname(result.files.single.path!);
              _outputPath = path.join(path.dirname(parentDir), 'output');
            }
          });
        } else {
          setState(() {
            _isLoading = false;
            _statusMessage = 'No points found in the selected date range in Timeline.json';
          });
        }
      } catch (e) {
        if (!mounted) return;
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
        
        if (!mounted) return;

        if (points.isNotEmpty) {
          final appState = context.read<AppStateProvider>();
          await appState.saveImportedPoints(points, 'gpx');

          if (!mounted) return;

          // Reload geotag providers with the new points
          context.read<GeotagProvider>().loadTimelineLocationsFromAppDb();
          context.read<BatchGeotagProvider>().loadTimelineLocationsFromAppDb();

          // Auto switch to MapViewerScreen tab (Index 5)
          appState.setIndex(5);

          setState(() {
            _lastImportedCount = points.length;
            _isLoading = false;
            _statusMessage = 'Successfully imported ${points.length} points from GPX to App Database!';
            if (_outputPath == null) {
              final parentDir = path.dirname(result.files.single.path!);
              _outputPath = path.join(path.dirname(parentDir), 'output');
            }
          });
        } else {
          setState(() {
            _isLoading = false;
            _statusMessage = 'No points found in the GPX file';
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _pickBatchFolder() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _isLoading = true;
        _statusMessage = 'Scanning folder...';
        _progress = 0.0;
      });

      try {
        final groups = await BatchImportService.scanDirectory(
          result,
          (progress, message) {
            if (mounted) {
              setState(() {
                _progress = progress;
                _statusMessage = message;
              });
            }
          },
        );

        if (groups.isEmpty) {
          if (mounted) {
            setState(() {
              _isLoading = false;
              _statusMessage = 'No valid GPX or JSON files found in folder';
            });
          }
          return;
        }

        if (mounted) {
          final List<FileGroup>? finalGroups =
              await Navigator.push<List<FileGroup>>(
            context,
            MaterialPageRoute(
              builder: (context) => ConflictResolverScreen(groups: groups),
            ),
          );

          if (!mounted) return;

          if (finalGroups != null && finalGroups.isNotEmpty) {
            final appState = context.read<AppStateProvider>();
            await appState.saveBatchGroups(finalGroups);

            if (!mounted) return;

            // Reload geotag providers with the new points
            context.read<GeotagProvider>().loadTimelineLocationsFromAppDb();
            context.read<BatchGeotagProvider>().loadTimelineLocationsFromAppDb();

            // Auto switch to MapViewerScreen tab (Index 5)
            appState.setIndex(5);

            int totalPts = 0;
            for (final g in finalGroups) {
              for (final f in g.files) {
                if (f.isSelected) totalPts += f.points.length;
              }
            }

            setState(() {
              _lastImportedCount = totalPts;
              _statusMessage = 'Successfully imported all files to App Database!';
              _outputPath ??= path.join(path.dirname(result), 'output');
            });
          }
        }

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error scanning folder: $e';
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
    if (_outputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select output folder')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Exporting from App Database...';
      _progress = 0.0;
    });

    try {
      final offset = context.read<SettingsProvider>().geotagTimezone.toDouble();
      final config = ExportConfig(
        mode: _exportMode,
        startDate: _startDate,
        endDate: _endDate,
        outputPath: _outputPath!,
        timezoneOffset: offset,
      );

      final appState = context.read<AppStateProvider>();
      final List<LocationPoint> pointsToExport = [];

      final filteredDates = appState.allDates.where((dateInfo) {
        if (config.startDate != null && dateInfo.date.isBefore(config.startDate!)) return false;
        if (dateInfo.date.isAfter(config.endDate)) return false;
        return true;
      }).toList();

      if (filteredDates.isEmpty) {
        throw Exception('No timeline records found in the database for the selected date range.');
      }

      int processedDates = 0;
      for (final dateInfo in filteredDates) {
        final pts = await LocationManager.loadLocationFile(dateInfo.filePath);
        pointsToExport.addAll(pts);
        processedDates++;
        setState(() {
          _progress = 0.1 + (processedDates / filteredDates.length) * 0.4;
          _statusMessage = 'Reading timeline date ${DateFormat('yyyy-MM-dd').format(dateInfo.date)}...';
        });
      }

      final result = await ExportService.export(
        points: pointsToExport,
        config: config,
        onProgress: (progress, message) {
          setState(() {
            _progress = 0.5 + progress * 0.5;
            _statusMessage = message;
          });
        },
      );

      setState(() {
        _isLoading = false;
        _statusMessage =
            'Exported ${result.pointsExported} points to ${result.filesCreated} files';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Export complete: ${result.filesCreated} files created')),
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
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Import Data',
                          style: Theme.of(context).textTheme.titleLarge),
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
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _isLoading ? null : _pickBatchFolder,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          foregroundColor:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                        icon: const Icon(Icons.drive_folder_upload),
                        label: const Text('Batch Import Folder (GPX/JSON)'),
                      ),
                      const SizedBox(height: 16),
                      Text('Time Filter',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ListTile(
                              title: Text(_startDate == null
                                  ? 'Start: All'
                                  : 'Start: ${DateFormat('yyyy-MM-dd').format(_startDate!)}'),
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
                              title: Text(
                                  'End: ${DateFormat('yyyy-MM-dd').format(_endDate)}'),
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
                      Text('Export Settings',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      SegmentedButton<ExportMode>(
                        segments: const [
                          ButtonSegment(
                            value: ExportMode.dailyFiles,
                            label: Text('Daily Files'),
                            icon: Icon(Icons.calendar_view_day),
                          ),
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
              if (_isLoading) LinearProgressIndicator(value: _progress),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Status',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(_statusMessage),
                      const SizedBox(height: 8),
                      Text('Last imported count: $_lastImportedCount points'),
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
}
