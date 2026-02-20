import 'dart:io';

import 'package:flutter/material.dart';
import 'package:native_exif/native_exif.dart';

import '../models/lens_template.dart';

class LensGroup {
  final double focalLength;
  final double fNumber;
  final List<File> files;
  LensTemplate? selectedTemplate;
  bool isProcessing = false;
  int successCount = 0;
  int errorCount = 0;

  LensGroup({
    required this.focalLength,
    required this.fNumber,
    required this.files,
  });

  String get groupName {
    if (focalLength == 0 && fNumber == 0) return 'No EXIF (or unable to read)';
    return '${focalLength}mm f/$fNumber';
  }
}

class LensMetadataProvider extends ChangeNotifier {
  List<LensGroup> groups = [];
  bool isScanning = false;

  void clearFiles() {
    groups.clear();
    notifyListeners();
  }

  Future<void> scanFiles(List<File> files) async {
    isScanning = true;
    notifyListeners();

    Map<String, LensGroup> groupMap = {};

    for (var file in files) {
      if (!file.path.toLowerCase().endsWith('.jpg') &&
          !file.path.toLowerCase().endsWith('.jpeg')) {
        continue;
      }

      double focalLength = 0;
      double fNumber = 0;

      try {
        final exif = await Exif.fromPath(file.path);
        final attrs = await exif.getAttributes();
        
        if (attrs != null) {
          if (attrs.containsKey('FocalLength')) {
            focalLength = _parseExifRational(attrs['FocalLength']);
          }
          if (attrs.containsKey('FNumber')) {
            fNumber = _parseExifRational(attrs['FNumber']);
          }
        }
        await exif.close();
      } catch (e) {
        // Ignore errors, they will fall into 0mm f/0 group
      }

      final key = '${focalLength}_$fNumber';
      if (!groupMap.containsKey(key)) {
        groupMap[key] = LensGroup(focalLength: focalLength, fNumber: fNumber, files: []);
      }
      groupMap[key]!.files.add(file);
    }

    groups = groupMap.values.toList();
    isScanning = false;
    notifyListeners();
  }

  double _parseExifRational(dynamic value) {
    if (value is String) return double.tryParse(value) ?? 0;
    if (value is num) return value.toDouble();
    return 0;
  }

  void assignTemplateToGroup(LensGroup group, LensTemplate? template) {
    group.selectedTemplate = template;
    notifyListeners();
  }

  Future<void> applyMetadataToGroup(LensGroup group) async {
    if (group.selectedTemplate == null || group.isProcessing) return;

    group.isProcessing = true;
    group.successCount = 0;
    group.errorCount = 0;
    notifyListeners();

    for (var file in group.files) {
      try {
        final exif = await Exif.fromPath(file.path);
        await exif.writeAttributes({
          'Lens': group.selectedTemplate!.name,
          'LensModel': group.selectedTemplate!.model,
          'LensMake': group.selectedTemplate!.make,
          'FocalLength': group.selectedTemplate!.focalLength.toString(),
          'FNumber': group.selectedTemplate!.fNumber.toString(),
        });
        await exif.close();
        group.successCount++;
      } catch (e) {
        group.errorCount++;
      }
    }

    group.isProcessing = false;
    notifyListeners();
  }
}
