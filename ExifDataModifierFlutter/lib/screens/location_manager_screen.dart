import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/location_manager.dart';
import '../providers/app_state_provider.dart';

class LocationManagerScreen extends StatefulWidget {
  const LocationManagerScreen({super.key});

  @override
  State<LocationManagerScreen> createState() => _LocationManagerScreenState();
}

class _LocationManagerScreenState extends State<LocationManagerScreen> {
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Scan storage on screen load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppStateProvider>().initializeAndScanAppStorage();
    });
  }

  Future<void> _refreshData(AppStateProvider appState) async {
    setState(() {
      _isLoading = true;
    });
    await appState.initializeAndScanAppStorage();
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _viewOnMap(AppStateProvider appState, DateInfo dateInfo) async {
    try {
      final points = await LocationManager.loadLocationFile(dateInfo.filePath);
      appState.togglePathVisibility(dateInfo, points);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading points: $e')),
        );
      }
    }
  }

  Future<void> _restoreToOriginal(AppStateProvider appState, DateInfo dateInfo) async {
    try {
      await appState.restoreDateToOriginal(dateInfo);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored ${DateFormat('yyyy-MM-dd').format(dateInfo.date)} to original backup.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    }
  }

  Future<void> _deleteDate(AppStateProvider appState, DateInfo dateInfo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Timeline Data'),
        content: Text('Are you sure you want to delete all timeline points for ${DateFormat('yyyy-MM-dd').format(dateInfo.date)}?\n\nThis will delete both the active and original data. This action is irreversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await appState.deleteDate(dateInfo);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Deleted successfully.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final dates = appState.allDates;
    final activePathIds = appState.activePaths.keys.toSet();

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Timeline Database',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${dates.length} dates imported',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                    ),
                  ],
                ),
                IconButton.filledTonal(
                  onPressed: _isLoading ? null : () => _refreshData(appState),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh Database',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_isLoading)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (dates.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.storage_rounded, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'Database is empty',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Go to "Timeline Import" tab to import your Google Timeline or GPX tracking files.',
                        textAlign: Center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: dates.length,
                itemBuilder: (context, index) {
                  final dateInfo = dates[index];
                  final isActive = activePathIds.contains(dateInfo.filePath);

                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                          isActive ? Icons.check : Icons.calendar_today,
                          color: isActive ? Colors.white : null,
                        ),
                      ),
                      title: Text(
                        DateFormat('yyyy-MM-dd').format(dateInfo.date),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text('${dateInfo.pointCount} location points'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _viewOnMap(appState, dateInfo),
                            child: Text(isActive ? 'SELECTED' : 'VIEW ON MAP'),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'restore') {
                                _restoreToOriginal(appState, dateInfo);
                              } else if (action == 'delete') {
                                _deleteDate(appState, dateInfo);
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'restore',
                                child: Row(
                                  children: [
                                    Icon(Icons.restore, size: 20),
                                    SizedBox(width: 8),
                                    Text('Restore Original'),
                                  ],
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_forever, color: Colors.red, size: 20),
                                    SizedBox(width: 8),
                                    Text('Delete', style: TextStyle(color: Colors.red)),
                                  ],
                                ),
                              ),
                            ],
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
    );
  }
}
