import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lens_template.dart';
import '../providers/lens_metadata_provider.dart';
import '../providers/settings_provider.dart';

class LensMetadataScreen extends StatelessWidget {
  const LensMetadataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        final files = detail.files.map((e) => File(e.path)).toList();
        context.read<LensMetadataProvider>().scanFiles(files);
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 16),
            Expanded(child: _buildGroupList(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<LensMetadataProvider>();
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manual Lens Metadata', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Group photos by current focal length and aperture, then apply manual lens metadata.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: provider.isScanning
                        ? null
                        : () async {
                            String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                            if (selectedDirectory != null) {
                              final dir = Directory(selectedDirectory);
                              final List<File> files = [];
                              await for (FileSystemEntity entity in dir.list(recursive: false)) {
                                if (entity is File) files.add(entity);
                              }
                              if (context.mounted) {
                                context.read<LensMetadataProvider>().scanFiles(files);
                              }
                            }
                          },
                    icon: provider.isScanning
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.folder),
                    label: Text(provider.isScanning ? 'Scanning...' : 'Select Folder'),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: provider.isScanning ? null : () => context.read<LensMetadataProvider>().clearFiles(),
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupList(BuildContext context) {
    final provider = context.watch<LensMetadataProvider>();
    final settingsProvider = context.watch<SettingsProvider>();

    if (provider.groups.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('Select a folder or drag photos to group them by EXIF', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: provider.groups.length,
      itemBuilder: (context, index) {
        final group = provider.groups[index];
        return Card(
          elevation: 1,
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Group: ${group.groupName}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('${group.files.length} Photos', style: const TextStyle(color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<LensTemplate>(
                        decoration: const InputDecoration(
                          labelText: 'Select Lens Template',
                          border: OutlineInputBorder(),
                        ),
                        value: group.selectedTemplate,
                        items: [
                          const DropdownMenuItem<LensTemplate>(value: null, child: Text('None')),
                          ...settingsProvider.lensTemplates.map((lens) {
                            return DropdownMenuItem<LensTemplate>(
                              value: lens,
                              child: Text('${lens.name} (${lens.focalLength}mm f/${lens.fNumber})'),
                            );
                          }).toList(),
                        ],
                        onChanged: group.isProcessing
                            ? null
                            : (val) {
                                context.read<LensMetadataProvider>().assignTemplateToGroup(group, val);
                              },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 1,
                      child: FilledButton.icon(
                        onPressed: group.selectedTemplate == null || group.isProcessing
                            ? null
                            : () => context.read<LensMetadataProvider>().applyMetadataToGroup(group),
                        icon: group.isProcessing
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.save),
                        label: Text(group.isProcessing ? 'Processing' : 'Write EXIF'),
                      ),
                    ),
                  ],
                ),
                if (group.successCount > 0 || group.errorCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      'Success: ${group.successCount}, Error: ${group.errorCount}',
                      style: TextStyle(color: group.errorCount > 0 ? Colors.red : Colors.green),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
