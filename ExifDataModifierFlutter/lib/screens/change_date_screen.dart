import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../providers/change_date_provider.dart';

class ChangeDateScreen extends StatefulWidget {
  const ChangeDateScreen({super.key});

  @override
  State<ChangeDateScreen> createState() => _ChangeDateScreenState();
}

class _ChangeDateScreenState extends State<ChangeDateScreen> {
  late TextEditingController _maskController;

  @override
  void initState() {
    super.initState();
    final provider = context.read<ChangeDateProvider>();
    _maskController = TextEditingController(text: provider.activeMask);
  }

  @override
  void dispose() {
    _maskController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChangeDateProvider>();

    // Keep text controller in sync if activeMask changes externally
    if (_maskController.text != provider.activeMask && !provider.isProcessing) {
      _maskController.text = provider.activeMask;
    }

    return DropTarget(
      onDragDone: (detail) {
        if (context.read<AppStateProvider>().currentIndex != 0) return;
        final files = detail.files.map((e) => File(e.path)).toList();
        context.read<ChangeDateProvider>().addFiles(files);
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 12),
            _buildControlsRow(context, provider),
            const SizedBox(height: 12),
            Expanded(child: _buildFileList(context, provider)),
            const SizedBox(height: 12),
            _buildBottomBar(context, provider),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Change Created & Modified Date',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Extract the date from filenames and apply it to file metadata.\n'
              'Select a pattern group from the dropdown, adjust the format mask if needed, then apply.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  // ── Controls Row (Dropdown + Mask Textfield + Add Buttons) ─────────────────

  Widget _buildControlsRow(BuildContext context, ChangeDateProvider provider) {
    final groups = provider.groups;

    // Build dropdown items
    final dropdownItems = <DropdownMenuItem<String>>[];

    if (provider.items.isNotEmpty) {
      dropdownItems.add(
        DropdownMenuItem<String>(
          value: 'ALL',
          child: Text('Tắt gom nhóm – Hiện tất cả (${provider.items.length} file)'),
        ),
      );

      final sortedKeys = groups.keys.toList()
        ..sort((a, b) {
          if (a.isEmpty) return 1;
          if (b.isEmpty) return -1;
          return (groups[b]?.length ?? 0).compareTo(groups[a]?.length ?? 0);
        });

      for (final key in sortedKeys) {
        final count = groups[key]?.length ?? 0;
        final label = key.isEmpty
            ? 'No pattern detected ($count)'
            : '$key ($count)';
        dropdownItems.add(
          DropdownMenuItem<String>(
            value: key,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: key.isNotEmpty ? 'monospace' : null,
                fontSize: 13,
                color: key.isEmpty ? Colors.orange[800] : null,
                fontWeight: key.isEmpty ? FontWeight.w500 : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    }

    final currentSelectedValue =
        (dropdownItems.any((i) => i.value == provider.selectedGroupKey))
            ? provider.selectedGroupKey
            : (dropdownItems.isNotEmpty ? dropdownItems.first.value : null);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1: Dropdown & Add buttons
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Single Pattern Dropdown
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: currentSelectedValue,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Detected Pattern Group',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    items: dropdownItems,
                    onChanged: provider.items.isEmpty || provider.isProcessing
                        ? null
                        : (v) {
                            if (v != null) {
                              provider.selectGroupKey(v);
                            }
                          },
                  ),
                ),
                const SizedBox(width: 12),
                // Add Files button
                OutlinedButton.icon(
                  onPressed: provider.isProcessing
                      ? null
                      : () async {
                          final result = await FilePicker.platform
                              .pickFiles(allowMultiple: true);
                          if (result != null && context.mounted) {
                            final files = result.paths
                                .where((p) => p != null)
                                .map((p) => File(p!))
                                .toList();
                            provider.addFiles(files);
                          }
                        },
                  icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                  label: const Text('Add Files'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 16),
                  ),
                ),
                const SizedBox(width: 8),
                // Add Folder button
                _AddFolderButton(),
              ],
            ),

            const SizedBox(height: 12),

            // Row 2: Format Mask Textfield
            TextFormField(
              controller: _maskController,
              enabled: provider.items.isNotEmpty && !provider.isProcessing,
              decoration: const InputDecoration(
                labelText: 'Format Mask',
                hintText: 'e.g. *yyyyMMdd*HHmmss',
                border: OutlineInputBorder(),
                helperText:
                    'Tokens: yyyy yy MM dd HH mm ss  |  * = wildcard prefix/suffix',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (val) {
                provider.updateActiveMask(val);
              },
            ),

            const SizedBox(height: 4),

            // Row 3: Wildcard Separators Checkbox
            Row(
              children: [
                Checkbox(
                  value: provider.useWildcardSeparators,
                  onChanged: provider.isProcessing
                      ? null
                      : (v) => provider.toggleUseWildcardSeparators(v ?? true),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: provider.isProcessing
                        ? null
                        : () => provider.toggleUseWildcardSeparators(
                            !provider.useWildcardSeparators),
                    child: Text(
                      'Gộp các dấu phân cách (- _ . khoảng trắng) thành * khi phân nhóm',
                      style: TextStyle(
                        fontSize: 13,
                        color: provider.items.isEmpty
                            ? Colors.grey
                            : Colors.grey[800],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── File List ──────────────────────────────────────────────────────────────

  Widget _buildFileList(BuildContext context, ChangeDateProvider provider) {
    final list = provider.visibleItems;

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
              Icon(Icons.upload_file, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('Drag & drop files or use the buttons above',
                  style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('Supports individual files or entire folders',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    final total = list.length;
    final matched = list.where((i) => !i.isError).length;
    final failed = list.where((i) => i.isError && !i.isSuccess).length;
    final done = list.where((i) => i.isSuccess).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary stats bar
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              _Chip(
                  label: '$total in group',
                  color: Theme.of(context).colorScheme.secondary),
              const SizedBox(width: 6),
              _Chip(label: '$matched matched', color: Colors.blue),
              const SizedBox(width: 6),
              if (failed > 0) ...[
                _Chip(label: '$failed no match', color: Colors.orange),
                const SizedBox(width: 6),
              ],
              if (done > 0) _Chip(label: '$done applied', color: Colors.green),
            ],
          ),
        ),

        // List
        Expanded(
          child: Card(
            elevation: 2,
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = list[index];
                return _FileListTile(
                  item: item,
                  onRemove: () => provider.removeFile(item),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ── Bottom Action Bar ──────────────────────────────────────────────────────

  Widget _buildBottomBar(BuildContext context, ChangeDateProvider provider) {
    final hasMatchedInVisible =
        provider.visibleItems.any((i) => !i.isError);
    final hasMatchedTotal = provider.items.any((i) => !i.isError);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (provider.isProcessing) ...[
          LinearProgressIndicator(
            value: provider.progressTotal > 0
                ? provider.progressCurrent / provider.progressTotal
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            provider.progressLabel,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            // Date Taken checkbox
            Checkbox(
              value: provider.setDateTaken,
              onChanged: provider.isProcessing
                  ? null
                  : (v) => provider.toggleSetDateTaken(v ?? false),
            ),
            Expanded(
              child: GestureDetector(
                onTap: provider.isProcessing
                    ? null
                    : () =>
                        provider.toggleSetDateTaken(!provider.setDateTaken),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Also set Date Taken (EXIF)',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Writes DateTimeOriginal / CreateDate / ModifyDate inside the file via ExifTool',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: provider.items.isEmpty || provider.isProcessing
                  ? null
                  : () => provider.clearFiles(),
              child: const Text('Clear List'),
            ),
            const SizedBox(width: 8),
            // Apply Current Group
            OutlinedButton.icon(
              onPressed: (!hasMatchedInVisible || provider.isProcessing)
                  ? null
                  : () => provider.applyGroup(),
              icon: const Icon(Icons.playlist_add_check, size: 18),
              label: const Text('Apply Group'),
            ),
            const SizedBox(width: 8),
            // Apply All
            FilledButton.icon(
              onPressed: (!hasMatchedTotal || provider.isProcessing)
                  ? null
                  : () => provider.applyChanges(),
              icon: provider.isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save),
              label: Text(
                  provider.isProcessing ? 'Processing…' : 'Apply All'),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Add Folder Button ─────────────────────────────────────────────────────────

class _AddFolderButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => _showFolderOptions(context),
      icon: const Icon(Icons.folder_open, size: 18),
      label: const Text('Add Folder'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
    );
  }

  void _showFolderOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('Top-level only'),
              subtitle: const Text('Files directly inside the chosen folder'),
              onTap: () {
                Navigator.pop(ctx);
                context
                    .read<ChangeDateProvider>()
                    .pickAndAddFolder(recursive: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_special),
              title: const Text('Recursive (include sub-folders)'),
              subtitle: const Text('All files in folder and sub-folders'),
              onTap: () {
                Navigator.pop(ctx);
                context
                    .read<ChangeDateProvider>()
                    .pickAndAddFolder(recursive: true);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }
}

// ── File List Tile ─────────────────────────────────────────────────────────────

class _FileListTile extends StatelessWidget {
  const _FileListTile({required this.item, required this.onRemove});

  final FileDateItem item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final IconData iconData;
    final Color iconColor;
    final String subtitle;
    final Color subtitleColor;

    if (item.isSuccess) {
      iconData = Icons.check_circle;
      iconColor = Colors.green;
      subtitle = 'Applied → ${_fmt(item.extractedDate!)}';
      subtitleColor = Colors.green;
    } else if (item.isError) {
      iconData = Icons.error_outline;
      iconColor = Colors.red;
      subtitle = 'No match – check format mask';
      subtitleColor = Colors.red;
    } else if (item.extractedDate != null) {
      iconData = Icons.insert_drive_file;
      iconColor = Colors.blue;
      subtitle = 'Preview → ${_fmt(item.extractedDate!)}';
      subtitleColor = Colors.blue;
    } else {
      iconData = Icons.insert_drive_file;
      iconColor = Colors.grey;
      subtitle = 'Pending';
      subtitleColor = Colors.grey;
    }

    return ListTile(
      dense: true,
      leading: Icon(iconData, color: iconColor, size: 22),
      title: Text(
        item.filename,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: subtitleColor, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        color: Colors.red,
        onPressed: onRemove,
        tooltip: 'Remove',
      ),
    );
  }

  static String _fmt(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
      '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

// ── Small Stat Chip ────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
