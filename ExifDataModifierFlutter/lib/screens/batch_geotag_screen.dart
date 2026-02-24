import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../providers/batch_geotag_provider.dart';
import '../providers/settings_provider.dart';

class BatchGeotagScreen extends StatefulWidget {
  const BatchGeotagScreen({super.key});

  @override
  State<BatchGeotagScreen> createState() => _BatchGeotagScreenState();
}

class _BatchGeotagScreenState extends State<BatchGeotagScreen> {
  // ── Filter ───────────────────────────────────────────────────────────────
  BatchItemStatus? _filterStatus; // null = show all
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Toast ────────────────────────────────────────────────────────────────
  void _showToast(String message,
      {IconData icon = Icons.check_circle,
      Color color = Colors.green,
      Duration duration = const Duration(seconds: 3)}) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        icon: icon,
        color: color,
        duration: duration,
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  // ── Folder pickers ────────────────────────────────────────────────────────
  Future<void> _pickImageFolder(BuildContext ctx) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Image Folder',
    );
    if (result != null && ctx.mounted) {
      _showToast('Scanning image folder…',
          icon: Icons.folder_open, color: Colors.blue);
      await ctx.read<BatchGeotagProvider>().scanImageFolder(result);
      if (ctx.mounted) {
        final provider = ctx.read<BatchGeotagProvider>();
        _showToast(
          'Found ${provider.items.length} files',
          icon: Icons.photo_library,
          color: Colors.blue,
        );
        // Show any ExifTool diagnostic as a separate warning toast
        final exifLog = provider.lastExifLog;
        if (exifLog != null && ctx.mounted) {
          provider.lastExifLog = null; // consume
          _showToast(exifLog,
              icon: Icons.warning_amber_rounded,
              color: Colors.orange,
              duration: const Duration(seconds: 8));
        }
      }
    }
  }

  Future<void> _pickTimelineFolder(BuildContext ctx) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Timeline Folder',
    );
    if (result != null && ctx.mounted) {
      _showToast('Loading timelines…',
          icon: Icons.timeline, color: Colors.purple);
      await ctx.read<BatchGeotagProvider>().loadTimelineFolder(result);
      if (ctx.mounted) {
        final p = ctx.read<BatchGeotagProvider>();
        _showToast(
          'Loaded ${p.timelineLocations.length} GPS points',
          icon: Icons.timeline,
          color: Colors.green,
        );
      }
    }
  }

  Future<void> _pickOutputFolder(BuildContext ctx) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Folder',
    );
    if (result != null && ctx.mounted) {
      ctx.read<BatchGeotagProvider>().setOutputFolder(result);
    }
  }

  Future<void> _runProcess(BuildContext ctx) async {
    final provider = ctx.read<BatchGeotagProvider>();
    if (provider.outputFolderPath == null) {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Output Folder',
      );
      if (result == null || !ctx.mounted) return;
      provider.setOutputFolder(result);
    }
    await provider.processAndCopy(provider.outputFolderPath!);
    if (ctx.mounted) {
      _showToast(
        'Done! Geotagged: ${provider.countDone} | Copied: ${provider.countCopiedOnly}',
        icon: Icons.check_circle,
        color: Colors.green,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const SizedBox(height: 12),
          _buildSummaryBar(context),
          const SizedBox(height: 12),
          Expanded(child: _buildFileList(context)),
          const SizedBox(height: 12),
          _buildActionBar(context),
        ],
      ),
    );
  }

  // ── Header card ───────────────────────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<BatchGeotagProvider>();
    final isBusy = provider.isBusy;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row
            Row(
              children: [
                const Icon(Icons.photo_library_outlined,
                    color: Colors.deepPurple),
                const SizedBox(width: 8),
                Text('Batch Geotag',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (!isBusy)
                  OutlinedButton.icon(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => _SettingsDialog(provider: provider),
                      );
                    },
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('Settings'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Three folder choosers ──────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _FolderPickerTile(
                    icon: Icons.photo_library,
                    iconColor: Colors.blue,
                    label: 'Image Folder',
                    path: provider.imageFolderPath,
                    subtitle: provider.imageFolderPath != null
                        ? '${provider.items.length} files found'
                        : 'Select folder to scan recursively',
                    onTap: isBusy ? null : () => _pickImageFolder(context),
                    onClear: isBusy || provider.imageFolderPath == null
                        ? null
                        : () => provider.clearImages(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _FolderPickerTile(
                    icon: Icons.timeline,
                    iconColor: Colors.purple,
                    label: 'Timeline Folder',
                    path: provider.timelineFolderPath,
                    subtitle: provider.timelineFolderPath != null
                        ? '${provider.timelineLocations.length} GPS points from ${provider.loadedTimelineFiles.length} files'
                        : 'Select folder with JSON timeline files',
                    onTap: isBusy ? null : () => _pickTimelineFolder(context),
                    onClear: isBusy || provider.timelineFolderPath == null
                        ? null
                        : () => provider.clearTimelines(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _FolderPickerTile(
                    icon: Icons.drive_folder_upload,
                    iconColor: Colors.green,
                    label: 'Output Folder',
                    path: provider.outputFolderPath,
                    subtitle: provider.outputFolderPath != null
                        ? 'Geotagged copies will go here'
                        : 'Where to save geotagged copies',
                    onTap: isBusy ? null : () => _pickOutputFolder(context),
                    onClear: isBusy || provider.outputFolderPath == null
                        ? null
                        : () => provider.setOutputFolder(null),
                  ),
                ),
              ],
            ),

            // ── Progress bar ───────────────────────────────────────────────
            if (isBusy) ...[
              const SizedBox(height: 12),
              _buildProgressSection(provider),
            ],

            // ── Status message ─────────────────────────────────────────────
            if (provider.statusMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withOpacity(0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  provider.statusMessage,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection(BatchGeotagProvider provider) {
    String label;
    double? value;

    if (provider.isScanning) {
      label = 'Scanning… ${provider.scannedCount} / ${provider.totalToScan}';
      value = provider.totalToScan == 0
          ? null
          : provider.scannedCount / provider.totalToScan;
    } else if (provider.isLoadingTimelines) {
      label =
          'Loading timelines… ${provider.loadedTimelineCount} / ${provider.totalTimelines}';
      value = provider.totalTimelines == 0
          ? null
          : provider.loadedTimelineCount / provider.totalTimelines;
    } else if (provider.isMatching) {
      label = 'Matching… ${provider.matchedCount} / ${provider.totalToMatch}';
      value = provider.totalToMatch == 0
          ? null
          : provider.matchedCount / provider.totalToMatch;
    } else if (provider.isProcessing) {
      label =
          'Processing… ${provider.processedCount} / ${provider.totalToProcess}';
      value = provider.totalToProcess == 0
          ? null
          : provider.processedCount / provider.totalToProcess;
    } else {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Cancel button
            TextButton.icon(
              onPressed: () {
                if (provider.isScanning || provider.isLoadingTimelines) {
                  provider.cancelScan();
                } else if (provider.isMatching) {
                  provider.cancelMatch();
                } else if (provider.isProcessing) {
                  provider.cancelProcess();
                }
              },
              icon: const Icon(Icons.stop_circle_outlined,
                  size: 14, color: Colors.redAccent),
              label: const Text('Stop',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: value),
        ),
      ],
    );
  }

  // ── Summary bar ───────────────────────────────────────────────────────────
  Widget _buildSummaryBar(BuildContext context) {
    final provider = context.watch<BatchGeotagProvider>();
    if (provider.items.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StatChip(
              label: 'Total',
              count: provider.items.length,
              color: Colors.grey,
              icon: Icons.photo,
              onTap: () => setState(() => _filterStatus = null),
              selected: _filterStatus == null,
            ),
            _StatChip(
              label: 'Matched',
              count: provider.countMatched,
              color: Colors.blue,
              icon: Icons.location_on,
              onTap: () =>
                  setState(() => _filterStatus = BatchItemStatus.matched),
              selected: _filterStatus == BatchItemStatus.matched,
            ),
            _StatChip(
              label: 'Has GPS',
              count: provider.countSkippedGps,
              color: Colors.amber.shade700,
              icon: Icons.warning_amber,
              onTap: () =>
                  setState(() => _filterStatus = BatchItemStatus.skippedHasGps),
              selected: _filterStatus == BatchItemStatus.skippedHasGps,
            ),
            _StatChip(
              label: 'No Match',
              count: provider.countNoMatch,
              color: Colors.red,
              icon: Icons.location_off,
              onTap: () =>
                  setState(() => _filterStatus = BatchItemStatus.noMatch),
              selected: _filterStatus == BatchItemStatus.noMatch,
            ),
            _StatChip(
              label: 'Unsupported',
              count: provider.countUnsupported,
              color: Colors.grey.shade600,
              icon: Icons.block,
              onTap: () => setState(
                  () => _filterStatus = BatchItemStatus.skippedUnsupported),
              selected: _filterStatus == BatchItemStatus.skippedUnsupported,
            ),
            _StatChip(
              label: 'Done',
              count: provider.countDone,
              color: Colors.green,
              icon: Icons.check_circle,
              onTap: () => setState(() => _filterStatus = BatchItemStatus.done),
              selected: _filterStatus == BatchItemStatus.done,
            ),
            _StatChip(
              label: 'Copied',
              count: provider.countCopiedOnly,
              color: Colors.orange,
              icon: Icons.copy,
              onTap: () =>
                  setState(() => _filterStatus = BatchItemStatus.copiedOnly),
              selected: _filterStatus == BatchItemStatus.copiedOnly,
            ),
            if (provider.countError > 0)
              _StatChip(
                label: 'Error',
                count: provider.countError,
                color: Colors.red.shade700,
                icon: Icons.error,
                onTap: () =>
                    setState(() => _filterStatus = BatchItemStatus.error),
                selected: _filterStatus == BatchItemStatus.error,
              ),
          ],
        ),
      ),
    );
  }

  // ── File list ─────────────────────────────────────────────────────────────
  Widget _buildFileList(BuildContext context) {
    final provider = context.watch<BatchGeotagProvider>();

    if (provider.items.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(
              color: Theme.of(context).dividerColor, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_library_outlined,
                  size: 56,
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
              const SizedBox(height: 16),
              Text(
                'Select an image folder to get started.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.5),
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'All images including subfolders will be listed here.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.4),
                    ),
              ),
            ],
          ),
        ),
      );
    }

    // Apply filter
    final filtered = provider.items.where((item) {
      if (_filterStatus != null && item.status != _filterStatus) return false;
      if (_searchQuery.isNotEmpty &&
          !item.filename.toLowerCase().contains(_searchQuery.toLowerCase()) &&
          !item.relativePath.toLowerCase().contains(_searchQuery.toLowerCase()))
        return false;
      return true;
    }).toList();

    return Card(
      elevation: 2,
      child: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search filename or path…',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          // Count row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withOpacity(0.4),
            child: Row(
              children: [
                Text(
                  'Showing ${filtered.length} of ${provider.items.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.6)),
                ),
                const Spacer(),
                if (_filterStatus != null)
                  TextButton(
                    onPressed: () => setState(() => _filterStatus = null),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Clear filter',
                        style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No items match the current filter.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.5)),
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return _buildItemTile(context, item);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemTile(BuildContext context, BatchGeotagItem item) {
    final isImage = item.isSupported;

    // Date string
    String dateStr = '';
    if (item.dateTaken != null) {
      final local = item.dateTaken!.toUtc().add(
          Duration(hours: context.read<BatchGeotagProvider>().geotagTimezone));
      dateStr = DateFormat('yyyy-MM-dd HH:mm').format(local);
    }

    final subtitle = [
      if (dateStr.isNotEmpty) dateStr,
      if (item.statusMessage != null) item.statusMessage!,
    ].join(' • ');

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: SizedBox(
        width: 40,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(item.statusIcon, color: item.statusColor, size: 20),
          ],
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              item.filename,
              style: const TextStyle(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!isImage)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                item.filename.contains('.')
                    ? item.filename.split('.').last.toUpperCase()
                    : 'FILE',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Relative path
          Text(
            item.relativePath,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: item.statusColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      isThreeLine: subtitle.isNotEmpty,
    );
  }

  // ── Action bar ─────────────────────────────────────────────────────────────
  Widget _buildActionBar(BuildContext context) {
    final provider = context.watch<BatchGeotagProvider>();
    final isBusy = provider.isBusy;

    final canMatch = !isBusy &&
        provider.items.isNotEmpty &&
        provider.timelineLocations.isNotEmpty;

    final canProcessAll = !isBusy && provider.items.isNotEmpty;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Reset button
            TextButton.icon(
              onPressed: isBusy
                  ? null
                  : () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Reset All?'),
                          content:
                              const Text('This will clear all loaded data.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () {
                                provider.reset();
                                Navigator.pop(context);
                              },
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                      );
                    },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset'),
            ),

            // Match location
            OutlinedButton.icon(
              onPressed: canMatch
                  ? () async {
                      await provider.matchLocations();
                      if (context.mounted) {
                        _showToast(
                          'Matched ${provider.countMatched} images',
                          icon: Icons.location_on,
                          color: Colors.blue,
                        );
                      }
                    }
                  : null,
              icon: provider.isMatching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 16),
              label:
                  Text(provider.isMatching ? 'Matching…' : 'Match Locations'),
            ),

            // Start processing
            FilledButton.icon(
              onPressed: canProcessAll ? () => _runProcess(context) : null,
              icon: provider.isProcessing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.copy_all, size: 18),
              label: Text(provider.isProcessing
                  ? 'Processing ${provider.processedCount}/${provider.totalToProcess}…'
                  : 'Copy & Geotag All'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Folder picker tile ────────────────────────────────────────────────────────

class _FolderPickerTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? path;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  const _FolderPickerTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.path,
    required this.subtitle,
    this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasPath = path != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hasPath
              ? iconColor.withOpacity(0.07)
              : Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasPath
                ? iconColor.withOpacity(0.3)
                : Theme.of(context).dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: hasPath ? iconColor : Colors.grey, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: hasPath ? iconColor : Colors.grey.shade600,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    path != null
                        ? path!.split(Platform.pathSeparator).last
                        : subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: hasPath
                          ? Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.7)
                          : Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (path != null)
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        color: iconColor.withOpacity(0.8),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (onClear != null)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: onClear,
                tooltip: 'Clear',
                color: Colors.grey,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              )
            else if (onTap != null)
              Icon(
                Icons.folder_open,
                size: 16,
                color: Colors.grey.shade400,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Stats chip ────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;

  const _StatChip({
    required this.label,
    required this.count,
    required this.color,
    required this.icon,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : color.withOpacity(0.3),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings dialog ───────────────────────────────────────────────────────────

class _SettingsDialog extends StatelessWidget {
  final BatchGeotagProvider provider;
  const _SettingsDialog({required this.provider});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, color: Colors.deepPurple),
          SizedBox(width: 8),
          Text('Batch Geotag Settings'),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Timezone
            Row(
              children: [
                const Text('Photo Timezone:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: provider.geotagTimezone,
                  isDense: true,
                  items: List.generate(29, (i) => i - 14)
                      .map((e) => DropdownMenuItem(
                          value: e, child: Text(e >= 0 ? 'UTC+$e' : 'UTC$e')))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      provider.setTimezone(val);
                      // Sync with global settings
                      context
                          .read<SettingsProvider>()
                          .updateGeotagTimezone(val);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Max gap
            Row(
              children: [
                const Text('Max Gap Between Points:',
                    style: TextStyle(fontSize: 14)),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: provider.maxInterpolationGapMinutes,
                  isDense: true,
                  items: [30, 60, 120, 240, 480, 720]
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text('${e}m')))
                      .toList(),
                  onChanged: (val) {
                    if (val != null)
                      provider.setMaxInterpolationGapMinutes(val);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Photos outside the max gap window will be classified as "No Match" and only copied without geotag.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ── Toast widget (reused from geotag_screen) ──────────────────────────────────

class _ToastWidget extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback onDismiss;
  final Duration duration;

  const _ToastWidget({
    required this.message,
    required this.icon,
    required this.color,
    required this.onDismiss,
    this.duration = const Duration(seconds: 3),
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
    Future.delayed(widget.duration, () {
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
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[900]?.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: widget.color.withOpacity(0.5),
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
