import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;

import '../models/lens_template.dart';
import '../providers/app_state_provider.dart';
import '../providers/lens_metadata_provider.dart';
import '../providers/settings_provider.dart';

class LensMetadataScreen extends StatefulWidget {
  const LensMetadataScreen({super.key});

  @override
  State<LensMetadataScreen> createState() => _LensMetadataScreenState();
}

class _LensMetadataScreenState extends State<LensMetadataScreen> {
  String? _hoveredPath;
  Timer? _hoverTimer;
  Offset? _hoverPosition;
  bool _isZoomed = false;

  void _onHover(String path, Offset position) {
    if (_hoveredPath == path) return;

    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 400), () {
      setState(() {
        _hoveredPath = path;
        _hoverPosition = position;
        _isZoomed = false;
      });
      // Small delay to trigger the animation from initial position
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) setState(() => _isZoomed = true);
      });
    });
  }

  void _onExit() {
    _hoverTimer?.cancel();
    setState(() {
      _hoveredPath = null;
      _isZoomed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        if (context.read<AppStateProvider>().currentIndex != 6) return;
        final files = detail.files.map((e) => File(e.path)).toList();
        final settings = context.read<SettingsProvider>();
        context.read<LensMetadataProvider>().scanFiles(
              files,
              availableTemplates: settings.lensTemplates,
              mappings: settings.lensMappings,
            );
      },
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(context),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left panel: Groups
                      SizedBox(
                        width: 300,
                        child: _buildGroupSidebar(context),
                      ),
                      const VerticalDivider(width: 32),
                      // Right panel: Files and Actions
                      Expanded(
                        child: _buildMainContent(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_hoveredPath != null) _buildLargePreview(context),
        ],
      ),
    );
  }

  Widget _buildLargePreview(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final startX = _hoverPosition?.dx ?? 0;
    final startY = _hoverPosition?.dy ?? 0;

    return Stack(
      children: [
        // Dark background fade in
        IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: _isZoomed ? 0.9 : 0.0,
            child: Container(color: Colors.black),
          ),
        ),
        // Animated Image Position
        AnimatedPositioned(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutQuart,
          left: _isZoomed ? 0 : startX,
          top: _isZoomed ? 0 : startY,
          width: _isZoomed ? size.width : 48,
          height: _isZoomed ? size.height : 48,
          child: IgnorePointer(
            child: Padding(
              padding: EdgeInsets.all(_isZoomed ? 40.0 : 0.0),
              child: Column(
                children: [
                  Expanded(
                    child: Image.file(
                      File(_hoveredPath!),
                      fit: BoxFit.contain,
                      errorBuilder: (c, e, s) => const Center(
                        child: Icon(Icons.broken_image,
                            color: Colors.white54, size: 128),
                      ),
                    ),
                  ),
                  if (_isZoomed) ...[
                    const SizedBox(height: 16),
                    Text(
                      p.basename(_hoveredPath!),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(blurRadius: 10)],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<LensMetadataProvider>();
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lens Metadata Grouping',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                      'Group photos by EXIF focal length/aperture to batch update correct lens data.',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: provider.isScanning
                  ? null
                  : () async {
                      String? selectedDirectory =
                          await FilePicker.platform.getDirectoryPath();
                      if (selectedDirectory != null) {
                        final dir = Directory(selectedDirectory);
                        final List<File> files = [];
                        await for (FileSystemEntity entity
                            in dir.list(recursive: false)) {
                          if (entity is File) files.add(entity);
                        }
                        if (context.mounted) {
                          final settings = context.read<SettingsProvider>();
                          context.read<LensMetadataProvider>().scanFiles(
                                files,
                                availableTemplates: settings.lensTemplates,
                                mappings: settings.lensMappings,
                              );
                        }
                      }
                    },
              icon: provider.isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.folder),
              label:
                  Text(provider.isScanning ? 'Scanning...' : 'Select Folder'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: provider.groups.isEmpty
                  ? null
                  : () => context.read<LensMetadataProvider>().clearFiles(),
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear All'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupSidebar(BuildContext context) {
    final provider = context.watch<LensMetadataProvider>();
    if (provider.groups.isEmpty) {
      return const Center(
        child: Text('No groups yet', style: TextStyle(color: Colors.grey)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Text('DETECTED GROUPS (${provider.groups.length})',
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: provider.groups.length,
            itemBuilder: (context, index) {
              final group = provider.groups[index];
              final isSelected = provider.selectedGroup == group;
              return ListTile(
                selected: isSelected,
                title: Text(group.groupName),
                subtitle: Text('${group.items.length} photos'),
                trailing: group.successCount > 0
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
                onTap: () => provider.setSelectedGroup(group),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMainContent(BuildContext context) {
    final provider = context.watch<LensMetadataProvider>();
    final settings = context.watch<SettingsProvider>();
    final group = provider.selectedGroup;

    if (group == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_search, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('Select a group from the left to manage files',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Top Action Bar for the group
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<LensTemplate>(
                              decoration: const InputDecoration(
                                labelText: 'Apply Lens Template',
                                border: OutlineInputBorder(),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              initialValue: group.selectedTemplate,
                              items: [
                                const DropdownMenuItem<LensTemplate>(
                                    value: null,
                                    child: Text('Manual Assignment')),
                                ...settings.lensTemplates.map((lens) {
                                  return DropdownMenuItem<LensTemplate>(
                                    value: lens,
                                    child: Text(
                                        '${lens.name} (${lens.focalLength}mm f/${lens.fNumber})'),
                                  );
                                }),
                              ],
                              onChanged: group.isProcessing
                                  ? null
                                  : (val) {
                                      provider.assignTemplateToGroup(
                                          group, val);
                                    },
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(
                              group.isExpanded
                                  ? Icons.keyboard_arrow_up
                                  : Icons.tune,
                              color: Colors.indigo,
                            ),
                            tooltip: 'Override Parameters',
                            onPressed: group.selectedTemplate == null
                                ? null
                                : () => provider.toggleGroupExpanded(group),
                          ),
                        ],
                      ),
                      if (group.isExpanded &&
                          group.selectedTemplate != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.indigo.withValues(alpha: 0.2)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue: (group.overrideFocalLength ??
                                          group.selectedTemplate!.focalLength)
                                      .toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Focal Length (mm)',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (val) {
                                    final d = double.tryParse(val);
                                    provider.updateGroupOverrides(
                                        group, d, group.overrideFNumber);
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  initialValue: (group.overrideFNumber ??
                                          group.selectedTemplate!.fNumber)
                                      .toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Aperture (f/)',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (val) {
                                    final d = double.tryParse(val);
                                    provider.updateGroupOverrides(
                                        group, group.overrideFocalLength, d);
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 1,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                      backgroundColor: Colors.indigo,
                    ),
                    onPressed: group.selectedTemplate == null ||
                            group.isProcessing ||
                            !group.items.any((i) => i.isChecked)
                        ? null
                        : () => provider.applyMetadataToGroup(group),
                    icon: group.isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_fix_high),
                    label: Text(
                        group.isProcessing ? 'Writing...' : 'Write Metadata'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Selection Controls
        Row(
          children: [
            TextButton.icon(
              onPressed: () => provider.checkAllForSelectedGroup(true),
              icon: const Icon(Icons.check_box),
              label: const Text('Check All'),
            ),
            TextButton.icon(
              onPressed: () => provider.checkAllForSelectedGroup(false),
              icon: const Icon(Icons.check_box_outline_blank),
              label: const Text('Uncheck All'),
            ),
            const Spacer(),
            Text(
                '${group.items.where((i) => i.isChecked).length} / ${group.items.length} selected',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        // File list
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              itemCount: group.items.length,
              itemBuilder: (context, index) {
                final item = group.items[index];
                return CheckboxListTile(
                  title: Text(item.filename),
                  subtitle: Text(
                      'EXIF: ${item.originalExif}${group.selectedTemplate != null ? " → ${group.selectedTemplate!.name}" : ""}',
                      style: const TextStyle(fontSize: 12)),
                  value: item.isChecked,
                  onChanged: group.isProcessing
                      ? null
                      : (val) => provider.toggleItemCheck(item, val ?? false),
                  secondary: MouseRegion(
                    onHover: (event) => _onHover(item.path, event.position),
                    onExit: (_) => _onExit(),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.grey.shade200,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.file(
                        item.file,
                        fit: BoxFit.cover,
                        cacheWidth: 120,
                        errorBuilder: (c, e, s) =>
                            const Icon(Icons.image, color: Colors.grey),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
