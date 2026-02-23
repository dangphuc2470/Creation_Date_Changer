import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/lens_template.dart';

class LensGroup {
  final double focalLength;
  final double fNumber;
  final List<FileItem> items;
  LensTemplate? selectedTemplate;
  double? overrideFocalLength;
  double? overrideFNumber;
  bool isExpanded = false;
  bool isProcessing = false;
  int successCount = 0;
  int errorCount = 0;

  LensGroup({
    required this.focalLength,
    required this.fNumber,
    required this.items,
  });

  String get groupName {
    String base = (focalLength == 0 && fNumber == 0)
        ? 'Manual Lens (No EXIF)'
        : '${focalLength}mm f/$fNumber';
    if (selectedTemplate != null) {
      return '$base - ${selectedTemplate!.name}';
    }
    return base;
  }
}

class FileItem {
  final File file;
  final String path;
  final String filename;
  bool isChecked = true;
  String originalExif;

  FileItem({
    required this.file,
    required this.path,
    required this.filename,
    required this.originalExif,
  });
}

class LensMetadataProvider extends ChangeNotifier {
  List<LensGroup> groups = [];
  LensGroup? selectedGroup;
  bool isScanning = false;

  void clearFiles() {
    groups.clear();
    selectedGroup = null;
    notifyListeners();
  }

  void setSelectedGroup(LensGroup? group) {
    selectedGroup = group;
    notifyListeners();
  }

  void toggleItemCheck(FileItem item, bool value) {
    item.isChecked = value;
    notifyListeners();
  }

  void checkAllForSelectedGroup(bool value) {
    if (selectedGroup == null) return;
    for (var item in selectedGroup!.items) {
      item.isChecked = value;
    }
    notifyListeners();
  }

  Future<void> scanFiles(List<File> files,
      {List<LensTemplate>? availableTemplates,
      Map<String, String>? mappings}) async {
    isScanning = true;
    notifyListeners();

    final validFiles = files.where((f) {
      final ext = f.path.toLowerCase();
      return ext.endsWith('.jpg') || ext.endsWith('.jpeg');
    }).toList();

    if (validFiles.isEmpty) {
      isScanning = false;
      notifyListeners();
      return;
    }

    Map<String, LensGroup> groupMap = {};

    try {
      final exe = await _getExifToolExecutable();

      // Batch read focal length and f-number using CSV output
      // -n: numeric values for easier parsing
      final result = await Process.run(exe, [
        '-FocalLength',
        '-FNumber',
        '-n',
        '-csv',
        ...validFiles.map((f) => f.path),
      ]);

      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length > 1) {
          final headers = _parseCsvLine(lines[0]);
          final fileIdx = headers.indexOf('SourceFile');
          final focalIdx = headers.indexOf('FocalLength');
          final fNumIdx = headers.indexOf('FNumber');

          for (int i = 1; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.isEmpty) continue;

            final cols = _parseCsvLine(line);
            if (cols.length <= fileIdx) continue;

            final filePath = cols[fileIdx];
            double focalLength = 0;
            double fNumber = 0;

            if (focalIdx >= 0 && focalIdx < cols.length) {
              focalLength = double.tryParse(cols[focalIdx]) ?? 0;
            }
            if (fNumIdx >= 0 && fNumIdx < cols.length) {
              fNumber = double.tryParse(cols[fNumIdx]) ?? 0;
            }

            final signature = '${focalLength}_$fNumber';
            final mappedLensId = mappings?[signature];
            String key =
                mappedLensId != null ? 'mapped_$mappedLensId' : signature;

            if (!groupMap.containsKey(key)) {
              groupMap[key] = LensGroup(
                  focalLength: focalLength, fNumber: fNumber, items: []);

              if (availableTemplates != null && availableTemplates.isNotEmpty) {
                if (mappedLensId != null) {
                  groupMap[key]!.selectedTemplate =
                      availableTemplates.firstWhere(
                    (t) => t.id == mappedLensId,
                    orElse: () => null as dynamic,
                  );
                }
              }
            }

            groupMap[key]!.items.add(FileItem(
                  file: File(filePath),
                  path: filePath,
                  filename: p.basename(filePath),
                  originalExif: "Focal: ${focalLength}mm, f/$fNumber",
                ));
          }
        }
      }
    } catch (e) {
      // Fallback
    }

    groups = groupMap.values.toList();
    groups.sort((a, b) {
      if (a.focalLength != b.focalLength) {
        return a.focalLength.compareTo(b.focalLength);
      }
      return a.fNumber.compareTo(b.fNumber);
    });

    if (groups.isNotEmpty) selectedGroup = groups.first;
    isScanning = false;
    notifyListeners();
  }

  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuote = false;
    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuote = !inQuote;
      } else if (ch == ',' && !inQuote) {
        result.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString().trim());
    return result;
  }

  void assignTemplateToGroup(LensGroup group, LensTemplate? template) {
    group.selectedTemplate = template;
    if (template != null) {
      group.overrideFocalLength = template.focalLength;
      group.overrideFNumber = template.fNumber;
    } else {
      group.overrideFocalLength = null;
      group.overrideFNumber = null;
    }
    notifyListeners();
  }

  void updateGroupOverrides(LensGroup group, double? focal, double? fNumber) {
    group.overrideFocalLength = focal;
    group.overrideFNumber = fNumber;
    notifyListeners();
  }

  void toggleGroupExpanded(LensGroup group) {
    group.isExpanded = !group.isExpanded;
    notifyListeners();
  }

  Future<void> applyMetadataToGroup(LensGroup group) async {
    if (group.selectedTemplate == null || group.isProcessing) return;

    group.isProcessing = true;
    group.successCount = 0;
    group.errorCount = 0;
    notifyListeners();

    try {
      final exe = await _getExifToolExecutable();
      final tempDir = await getTemporaryDirectory();
      final argFile = File(
          '${tempDir.path}/lens_args_${DateTime.now().millisecondsSinceEpoch}.txt');

      final argBuf = StringBuffer();
      final focal =
          group.overrideFocalLength ?? group.selectedTemplate!.focalLength;
      final fNumber = group.overrideFNumber ?? group.selectedTemplate!.fNumber;

      argBuf.writeln('-Lens=${group.selectedTemplate!.name}');
      argBuf.writeln('-LensModel=${group.selectedTemplate!.model}');
      argBuf.writeln('-LensMake=${group.selectedTemplate!.make}');
      argBuf.writeln('-FocalLength=$focal');
      argBuf.writeln('-FNumber=$fNumber');
      final selectedItems = group.items.where((i) => i.isChecked).toList();
      if (selectedItems.isEmpty) {
        group.isProcessing = false;
        notifyListeners();
        return;
      }

      argBuf.writeln('-overwrite_original');

      for (var item in selectedItems) {
        // Add original EXIF as comment
        argBuf.writeln('-UserComment=Original: ${item.originalExif}');
        argBuf.writeln(item.path);
      }

      await argFile.writeAsString(argBuf.toString(), flush: true);

      final result = await Process.run(exe, ['-@', argFile.path]);

      if (result.exitCode == 0) {
        group.successCount = selectedItems.length;
        for (var item in selectedItems) {
          item.isChecked = false; // Reset after successful write
        }
      } else {
        throw Exception(result.stderr);
      }

      if (await argFile.exists()) await argFile.delete();
    } catch (e) {
      group.errorCount = group.items.length;
    }

    group.isProcessing = false;
    notifyListeners();
  }

  Future<String> _getExifToolExecutable() async {
    try {
      final result = await Process.run('exiftool', ['-ver']);
      if (result.exitCode == 0) return 'exiftool';
    } catch (_) {}

    if (Platform.isWindows) {
      final cPath = 'C:\\exiftool\\exiftool.exe';
      if (await File(cPath).exists()) return cPath;
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(p.join(appDir.path, 'exiftool.exe'));
      if (!(await exeFile.exists())) {
        final data = await rootBundle.load('assets/bin/exiftool.exe');
        final bytes = data.buffer.asUint8List();
        await exeFile.writeAsBytes(bytes);
      }
      return exeFile.path;
    } catch (e) {
      return 'exiftool';
    }
  }
}
