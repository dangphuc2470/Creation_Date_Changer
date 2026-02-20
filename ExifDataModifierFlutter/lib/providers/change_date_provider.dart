import 'dart:io';
import 'package:flutter/material.dart';

import '../utils/date_extractor.dart';
import '../utils/file_modifier.dart';

class FileDateItem {
  final File file;
  final String path;
  final String filename;
  DateTime? extractedDate;
  bool isError;
  bool isSuccess;

  FileDateItem({
    required this.file,
    required this.path,
    required this.filename,
    this.extractedDate,
    this.isError = false,
    this.isSuccess = false,
  });
}

class ChangeDateProvider extends ChangeNotifier {
  List<FileDateItem> items = [];
  String formatMask = '****yyyyMMdd*HHmmss';
  bool isProcessing = false;

  void setFormatMask(String mask) {
    formatMask = mask;
    notifyListeners();
  }

  void addFiles(List<File> files) {
    for (var file in files) {
      if (!items.any((item) => item.path == file.path)) {
        items.add(FileDateItem(
          file: file,
          path: file.path,
          filename: file.uri.pathSegments.last,
        ));
      }
    }
    previewDates();
  }

  void removeFile(FileDateItem item) {
    items.remove(item);
    notifyListeners();
  }

  void clearFiles() {
    items.clear();
    notifyListeners();
  }

  void previewDates() {
    for (var item in items) {
      final date = DateExtractor.extractDate(item.filename, formatMask);
      item.extractedDate = date;
      item.isError = date == null;
      item.isSuccess = false; // Reset success state on preview
    }
    notifyListeners();
  }

  Future<void> applyChanges() async {
    isProcessing = true;
    notifyListeners();

    for (var item in items) {
      if (item.extractedDate != null && !item.isError) {
        final success = await FileModifier.changeFileDates(item.path, item.extractedDate!);
        item.isSuccess = success;
        if (!success) item.isError = true;
      }
    }

    isProcessing = false;
    notifyListeners();
  }
}
