import 'dart:io';
import 'package:flutter/material.dart';

import '../utils/file_modifier.dart';

enum DateSource { creation, modified, taken }

class RenameFileItem {
  final File file;
  final String path;
  final String originalName;
  String? previewName;
  bool isError;
  bool isSuccess;

  RenameFileItem({
    required this.file,
    required this.path,
    required this.originalName,
    this.previewName,
    this.isError = false,
    this.isSuccess = false,
  });
}

class ChangeFilenameProvider extends ChangeNotifier {
  List<RenameFileItem> items = [];
  String formatMask = 'IMG_<yyyyMMdd_HHmmss>_[nnnn]';
  DateSource selectedSource = DateSource.creation;
  bool isProcessing = false;

  void setFormatMask(String mask) {
    formatMask = mask;
    notifyListeners();
  }

  void setDateSource(DateSource source) {
    selectedSource = source;
    notifyListeners();
  }

  void addFiles(List<File> files) {
    for (var file in files) {
      if (!items.any((item) => item.path == file.path)) {
        items.add(RenameFileItem(
          file: file,
          path: file.path,
          originalName: file.uri.pathSegments.last,
        ));
      }
    }
    previewNames();
  }

  void removeFile(RenameFileItem item) {
    items.remove(item);
    notifyListeners();
  }

  void clearFiles() {
    items.clear();
    notifyListeners();
  }

  Future<void> previewNames() async {
    int sequence = 1;
    for (var item in items) {
      try {
        DateTime date;
        final stat = await item.file.stat();
        
        switch (selectedSource) {
          case DateSource.creation:
            // Dart stat() accessed is closest reliable fallback on some systems, 
            // but modified is often more accurate cross-platform if not changed.
            date = stat.modified;
            break;
          case DateSource.modified:
            date = stat.modified;
            break;
          case DateSource.taken:
            // Placeholder: Exif data logic will be implemented later.
            // For now, fallback to modified date
            date = stat.modified;
            break;
        }

        // We use changeFilename dry-run to preview (we will modify the utility function later if needed)
        // For preview, we can just do the regex replace here for simplicity without renaming
        item.previewName = _generatePreviewName(formatMask, date, sequence);
        item.isError = false;
        item.isSuccess = false;
        sequence++;
      } catch (e) {
        item.isError = true;
      }
    }
    notifyListeners();
  }

  String _generatePreviewName(String template, DateTime date, int sequenceNum) {
      String newName = template;
      final dateRegex = RegExp(r'<([^>]+)>');
      final match = dateRegex.firstMatch(newName);
      if (match != null) {
        final formatStr = match.group(1)!;
        String dateStr = formatStr
            .replaceAll('yyyy', date.year.toString().padLeft(4, '0'))
            .replaceAll('yy', (date.year % 100).toString().padLeft(2, '0'))
            .replaceAll('MM', date.month.toString().padLeft(2, '0'))
            .replaceAll('dd', date.day.toString().padLeft(2, '0'))
            .replaceAll('HH', date.hour.toString().padLeft(2, '0'))
            .replaceAll('mm', date.minute.toString().padLeft(2, '0'))
            .replaceAll('ss', date.second.toString().padLeft(2, '0'));
        newName = newName.replaceFirst('<$formatStr>', dateStr);
      }

      final seqRegex = RegExp(r'\[(n+)\]');
      final seqMatch = seqRegex.firstMatch(newName);
      if (seqMatch != null) {
        final nString = seqMatch.group(1)!;
        final seqStr = sequenceNum.toString().padLeft(nString.length, '0');
        newName = newName.replaceFirst('[$nString]', seqStr);
      }
      return newName;
  }

  Future<void> applyChanges() async {
    isProcessing = true;
    notifyListeners();

    int sequence = 1;
    for (var item in items) {
      if (item.previewName != null && !item.isError) {
        DateTime date = (await item.file.stat()).modified; // Simplify for now
        final newPath = await FileModifier.changeFilename(item.path, formatMask, date, sequence);
        
        if (newPath != null) {
          item.isSuccess = true;
          // Update item file reference to the new file
          // item.file = File(newPath); // Dart doesn't allow changing final field, we would need to recreate or ignore 
        } else {
          item.isError = true;
        }
        sequence++;
      }
    }

    isProcessing = false;
    notifyListeners();
  }
}
