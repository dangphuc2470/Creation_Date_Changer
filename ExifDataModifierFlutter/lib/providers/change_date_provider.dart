import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/exiftool_service.dart';
import '../utils/date_extractor.dart';
import '../utils/file_modifier.dart';

class FileDateItem {
  final File file;
  final String path;
  final String filename;

  /// The mask assigned to this file (auto-detected or manually updated).
  String? detectedMask;

  DateTime? extractedDate;
  bool isError;
  bool isSuccess;

  FileDateItem({
    required this.file,
    required this.path,
    required this.filename,
    this.detectedMask,
    this.extractedDate,
    this.isError = false,
    this.isSuccess = false,
  });
}

class ChangeDateProvider extends ChangeNotifier {
  List<FileDateItem> items = [];

  /// Currently selected pattern key for filtering (e.g. '*yyyy-MM-dd HHmmss', '', or 'ALL').
  String? selectedGroupKey;

  // Whether to also write EXIF Date Taken tags (DateTimeOriginal / CreateDate /
  // ModifyDate inside the file) via ExifTool, in addition to file-system dates.
  bool setDateTaken = false;

  /// Whether to use wildcard '*' for separators when auto-detecting format masks.
  bool useWildcardSeparators = true;

  bool isProcessing = false;

  // Progress feedback during applyChanges
  int progressCurrent = 0;
  int progressTotal = 0;
  String progressLabel = '';

  void toggleUseWildcardSeparators(bool value) {
    useWildcardSeparators = value;
    for (var item in items) {
      item.detectedMask = DateExtractor.autoDetectMask(
        item.filename,
        useWildcardsForSeparators: useWildcardSeparators,
      );
    }
    _autoSelectBestGroup();
    _refreshAllDates();
    notifyListeners();
  }

  // ── Groups ────────────────────────────────────────────────────────────────

  /// Groups files by their detected mask.
  /// Key = mask string, value = files with that mask.
  /// Files with no detected mask are grouped under the key ''.
  Map<String, List<FileDateItem>> get groups {
    final map = <String, List<FileDateItem>>{};
    for (final item in items) {
      final key = item.detectedMask ?? '';
      map.putIfAbsent(key, () => []).add(item);
    }
    return map;
  }

  /// Returns the files that should be displayed in the list based on [selectedGroupKey].
  List<FileDateItem> get visibleItems {
    if (selectedGroupKey == null || selectedGroupKey == 'ALL') {
      return items;
    }
    return groups[selectedGroupKey] ?? [];
  }

  /// Returns the format mask string to display in the editable textbox.
  String get activeMask {
    if (selectedGroupKey != null &&
        selectedGroupKey != 'ALL' &&
        selectedGroupKey!.isNotEmpty) {
      return selectedGroupKey!;
    }
    // Fallback: check if the first visible item has a mask
    final firstWithMask =
        visibleItems.firstWhere((i) => i.detectedMask != null && i.detectedMask!.isNotEmpty,
            orElse: () => visibleItems.isNotEmpty ? visibleItems.first : FileDateItem(file: File(''), path: '', filename: ''));
    return firstWithMask.detectedMask ?? '*yyyyMMdd*HHmmss';
  }

  /// Selects a pattern group for filtering and textfield display.
  void selectGroupKey(String? key) {
    selectedGroupKey = key;
    notifyListeners();
  }

  /// Updates the mask for all files in the currently selected group (or all files if ALL is selected).
  void updateActiveMask(String newMask) {
    final targetItems = (selectedGroupKey == null || selectedGroupKey == 'ALL')
        ? items
        : (groups[selectedGroupKey] ?? []);

    final oldKey = selectedGroupKey;

    for (final item in targetItems) {
      item.detectedMask = newMask;
      final date = DateExtractor.extractDate(item.filename, newMask);
      item.extractedDate = date;
      item.isError = date == null;
      item.isSuccess = false;
    }

    // Update selectedGroupKey if it was pointing to the old pattern name
    if (oldKey != null && oldKey != 'ALL' && oldKey != '') {
      selectedGroupKey = newMask;
    }

    notifyListeners();
  }

  void toggleSetDateTaken(bool value) {
    setDateTaken = value;
    notifyListeners();
  }

  // ── File management ───────────────────────────────────────────────────────

  void addFiles(List<File> files) {
    for (var file in files) {
      final path = file.path;
      if (FileSystemEntity.isDirectorySync(path)) {
        _scanFolderInternal(path, recursive: true);
      } else if (FileSystemEntity.isFileSync(path)) {
        if (!items.any((item) => item.path == path)) {
          final filename = p.basename(path);
          final mask = DateExtractor.autoDetectMask(filename,
              useWildcardsForSeparators: useWildcardSeparators);
          items.add(FileDateItem(
            file: file,
            path: path,
            filename: filename,
            detectedMask: mask,
          ));
        }
      }
    }
    items.sort((a, b) => a.filename.compareTo(b.filename));
    _autoSelectBestGroup();
    _refreshAllDates();
    notifyListeners();
  }

  /// Scans all files inside [folderPath].
  /// Pass [recursive] = true to include all sub-directories.
  Future<void> addFolder(String folderPath, {bool recursive = true}) async {
    _scanFolderInternal(folderPath, recursive: recursive);
    items.sort((a, b) => a.filename.compareTo(b.filename));
    _autoSelectBestGroup();
    _refreshAllDates();
    notifyListeners();
  }

  void _scanFolderInternal(String folderPath, {bool recursive = true}) {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return;

    try {
      final entities = dir.listSync(recursive: recursive, followLinks: false);
      for (final entity in entities) {
        if (entity is File &&
            !items.any((item) => item.path == entity.path)) {
          final filename = p.basename(entity.path);
          final mask = DateExtractor.autoDetectMask(filename,
              useWildcardsForSeparators: useWildcardSeparators);
          items.add(FileDateItem(
            file: entity,
            path: entity.path,
            filename: filename,
            detectedMask: mask,
          ));
        }
      }
    } catch (_) {}
  }

  void _autoSelectBestGroup() {
    if (items.isEmpty) {
      selectedGroupKey = null;
      return;
    }
    final g = groups;
    if (g.isEmpty) return;

    // Pick the group with the most files, prioritizing non-empty keys
    String? bestKey;
    int maxCount = -1;

    for (final entry in g.entries) {
      if (entry.key.isNotEmpty && entry.value.length > maxCount) {
        maxCount = entry.value.length;
        bestKey = entry.key;
      }
    }

    selectedGroupKey = bestKey ?? g.keys.first;
  }

  /// Opens the OS folder-picker dialog and calls [addFolder] on the result.
  Future<void> pickAndAddFolder({bool recursive = false}) async {
    final selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath != null) {
      await addFolder(selectedPath, recursive: recursive);
    }
  }

  void removeFile(FileDateItem item) {
    items.remove(item);
    if (items.isEmpty) {
      selectedGroupKey = null;
    } else if (selectedGroupKey != 'ALL' && visibleItems.isEmpty) {
      _autoSelectBestGroup();
    }
    notifyListeners();
  }

  void clearFiles() {
    items.clear();
    selectedGroupKey = null;
    notifyListeners();
  }

  // ── Date extraction ───────────────────────────────────────────────────────

  /// Re-extracts dates for all items using each item's own detectedMask.
  void _refreshAllDates() {
    for (var item in items) {
      final mask = item.detectedMask;
      if (mask != null && mask.isNotEmpty) {
        final date = DateExtractor.extractDate(item.filename, mask);
        item.extractedDate = date;
        item.isError = date == null;
        item.isSuccess = false;
      } else {
        item.extractedDate = null;
        item.isError = true;
        item.isSuccess = false;
      }
    }
  }

  void previewDates() {
    _refreshAllDates();
    notifyListeners();
  }

  // ── Apply ─────────────────────────────────────────────────────────────────

  /// Applies changes only for the currently visible items (selected pattern group).
  Future<void> applyGroup() async {
    final validItems = visibleItems
        .where((i) => i.extractedDate != null && !i.isError)
        .toList();
    if (validItems.isEmpty) return;
    await _applyItems(validItems);
  }

  /// Applies changes for all items.
  Future<void> applyChanges() async {
    final validItems = items
        .where((i) => i.extractedDate != null && !i.isError)
        .toList();
    if (validItems.isEmpty) return;
    await _applyItems(validItems);
  }

  Future<void> _applyItems(List<FileDateItem> validItems) async {
    isProcessing = true;
    progressCurrent = 0;
    progressTotal = setDateTaken ? validItems.length * 2 : validItems.length;
    progressLabel = 'Setting file-system dates…';
    notifyListeners();

    try {
      final dateMap = <String, DateTime>{
        for (final i in validItems) i.path: i.extractedDate!,
      };

      // ── Phase 1: file-system dates ──────────────────────────────────────────
      final fsResults = await FileModifier.changeFileDatesBatch(
        dateMap,
        onProgress: (processed, _) {
          progressCurrent = processed;
          progressLabel =
              'Setting file-system dates… ($processed/${validItems.length})';
          notifyListeners();
        },
      );

      // Mark success / failure from Phase 1
      for (final item in validItems) {
        item.isSuccess = fsResults[item.path] ?? false;
        if (!item.isSuccess) item.isError = true;
      }
      notifyListeners();

      // ── Phase 2: EXIF Date Taken ────────────────────────────────────────────
      if (setDateTaken) {
        // Only attempt files that passed Phase 1
        final exifMap = <String, DateTime>{
          for (final i in validItems.where((i) => i.isSuccess))
            i.path: i.extractedDate!,
        };

        if (exifMap.isNotEmpty) {
          progressLabel = 'Writing EXIF Date Taken via ExifTool…';
          notifyListeners();

          final fsBase = progressCurrent;
          await ExifToolService.writeExifDatesBatch(
            exifMap,
            onProgress: (processed, total) {
              progressCurrent = fsBase + processed;
              progressLabel = 'Writing EXIF Date Taken… ($processed/$total)';
              notifyListeners();
            },
          );
        }
      }

      progressCurrent = progressTotal;
      progressLabel = 'Done';
    } catch (e) {
      progressLabel = 'Error: $e';
    } finally {
      isProcessing = false;
      notifyListeners();
    }
  }
}
