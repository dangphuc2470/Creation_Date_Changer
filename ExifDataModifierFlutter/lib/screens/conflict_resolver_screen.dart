import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/batch_import_service.dart';
import '../models/location_point.dart';

class ConflictResolverScreen extends StatefulWidget {
  final List<FileGroup> groups;

  const ConflictResolverScreen({super.key, required this.groups});

  @override
  State<ConflictResolverScreen> createState() => _ConflictResolverScreenState();
}

class _ConflictResolverScreenState extends State<ConflictResolverScreen> {
  late List<FileGroup> _groups;

  @override
  void initState() {
    super.initState();
    _groups = widget.groups;
    // By default, if there is a conflict, we might want to unselect one?
    // Or just let the user decide.
  }

  void _toggleFileSelection(GroupedFile file, bool? value) {
    setState(() {
      file.isSelected = value ?? false;
    });
  }

  List<LocationPoint> _getFinalPoints() {
    final List<LocationPoint> allPoints = [];
    for (final group in _groups) {
      allPoints.addAll(BatchImportService.mergeGroup(group));
    }
    return allPoints;
  }

  @override
  Widget build(BuildContext context) {
    final conflictGroups = _groups.where((g) => g.hasConflict).toList();
    final cleanGroups = _groups.where((g) => !g.hasConflict).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch Import Review'),
        actions: [
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context, _groups);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            icon: const Icon(Icons.check),
            label: const Text('IMPORT ALL'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (conflictGroups.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(
                      'Conflicts found in ${conflictGroups.length} days',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.orange.shade900,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildGroupCard(conflictGroups[index]),
                childCount: conflictGroups.length,
              ),
            ),
          ],
          if (cleanGroups.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Clean merges (${cleanGroups.length} days)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildGroupCard(cleanGroups[index]),
                childCount: cleanGroups.length,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _buildGroupCard(FileGroup group) {
    final hasConflict = group.hasConflict;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: hasConflict ? 2 : 0,
      color: hasConflict ? Colors.orange.shade50 : Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: hasConflict ? Colors.orange.shade300 : Colors.grey.shade300,
          width: hasConflict ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              hasConflict ? Icons.warning_amber_rounded : Icons.today,
              color: hasConflict ? Colors.orange : Colors.blue,
            ),
            title: Text(
              group.date,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: hasConflict ? Colors.orange.shade900 : null,
              ),
            ),
            subtitle: Text('${group.files.length} sources for this day'),
            trailing: hasConflict
                ? const Badge(
                    label: Text('CONFLICT'), backgroundColor: Colors.orange)
                : const Icon(Icons.check_circle_outline, color: Colors.green),
          ),
          const Divider(height: 1),
          ...group.files.map((file) {
            final timeFormat = DateFormat('HH:mm');
            final timeRange =
                '${timeFormat.format(file.startTime)} - ${timeFormat.format(file.endTime)}';

            return CheckboxListTile(
              value: file.isSelected,
              activeColor: hasConflict ? Colors.orange : null,
              onChanged: (val) => _toggleFileSelection(file, val),
              title: Text(file.fileName, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                '$timeRange (${file.points.length} pts)',
                style: const TextStyle(fontSize: 12),
              ),
              secondary: Icon(
                file.fileName.toLowerCase().endsWith('.gpx')
                    ? Icons.route
                    : Icons.description_outlined,
                size: 20,
              ),
            );
          }).toList(),
          if (hasConflict)
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.merge_type,
                        size: 20, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This day has points with identical timestamps but different locations. Select which file(s) to trust.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade900),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
