import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/change_date_provider.dart';

class ChangeDateScreen extends StatelessWidget {
  const ChangeDateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        final files = detail.files.map((e) => File(e.path)).toList();
        context.read<ChangeDateProvider>().addFiles(files);
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 16),
            Expanded(child: _buildFileList(context)),
            const SizedBox(height: 16),
            _buildActionButtons(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<ChangeDateProvider>();
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Change Created and Modified Date', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Extract the date from filename and apply it to file metadata.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: provider.formatMask,
                    decoration: const InputDecoration(
                      labelText: 'Format String',
                      hintText: 'e.g. ****yyyyMMdd*HHmmss',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      context.read<ChangeDateProvider>().setFormatMask(val);
                      context.read<ChangeDateProvider>().previewDates();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: () async {
                    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
                    if (result != null) {
                      final files = result.paths.where((p) => p != null).map((p) => File(p!)).toList();
                      if (context.mounted) {
                        context.read<ChangeDateProvider>().addFiles(files);
                      }
                    }
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Add Files'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(BuildContext context) {
    final provider = context.watch<ChangeDateProvider>();
    if (provider.items.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.upload_file, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('Drag and drop files here', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      child: ListView.separated(
        itemCount: provider.items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = provider.items[index];
          String subtext = 'Invalid Match';
          Color subtextColor = Colors.red;

          if (!item.isError && item.extractedDate != null) {
            subtext = item.extractedDate.toString();
            subtextColor = item.isSuccess ? Colors.green : Colors.blue;
          }

          return ListTile(
            leading: Icon(
              item.isSuccess ? Icons.check_circle : (item.isError ? Icons.error : Icons.insert_drive_file),
              color: item.isSuccess ? Colors.green : (item.isError ? Colors.red : Colors.grey),
            ),
            title: Text(item.filename),
            subtitle: Text(subtext, style: TextStyle(color: subtextColor)),
            trailing: IconButton(
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => context.read<ChangeDateProvider>().removeFile(item),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final provider = context.watch<ChangeDateProvider>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: provider.items.isEmpty || provider.isProcessing ? null : () => context.read<ChangeDateProvider>().clearFiles(),
          child: const Text('Clear List'),
        ),
        const SizedBox(width: 16),
        FilledButton.icon(
          onPressed: provider.items.isEmpty || provider.isProcessing ? null : () => context.read<ChangeDateProvider>().applyChanges(),
          icon: provider.isProcessing 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
              : const Icon(Icons.save),
          label: Text(provider.isProcessing ? 'Processing...' : 'Apply Changes'),
        ),
      ],
    );
  }
}
