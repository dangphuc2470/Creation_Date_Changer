import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/lens_template.dart';
import '../services/app_notifier.dart';

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

  // ── Debug logger ─────────────────────────────────────────────────────────
  /// Shorten an exception to a one-liner for toast display.
  static String _shortMsg(Object e) {
    final s = e.toString();
    final nl = s.indexOf('\n');
    return nl > 0 ? s.substring(0, nl) : s;
  }

  static File? _logFile;
  static File _getLogFile() {
    if (_logFile != null) return _logFile!;
    // Ghi cạnh file .exe đang chạy → build\windows\x64\runner\Debug\lens_debug.log
    final exeDir = p.dirname(Platform.resolvedExecutable);
    _logFile = File(p.join(exeDir, 'lens_debug.log'));
    return _logFile!;
  }

  static void _log(String msg) {
    try {
      final f = _getLogFile();
      final ts = DateTime.now().toIso8601String();
      f.writeAsStringSync('[$ts] $msg\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  // Supported image extensions for lens metadata scanning
  static const _supportedExts = {
    'jpg',
    'jpeg',
    'arw',
    'cr2',
    'cr3',
    'nef',
    'raf',
    'orf',
    'dng',
    'rw2',
    'srw',
    'pef',
    'x3f',
    'tif',
    'tiff',
  };

  Future<void> scanFiles(List<File> files,
      {List<LensTemplate>? availableTemplates,
      Map<String, String>? mappings}) async {
    isScanning = true;
    notifyListeners();

    // Log all unique extensions found in the folder before filtering
    _log('=== scanFiles called ===');
    _log('Total files passed in: ${files.length}');
    final extCounts = <String, int>{};
    for (final f in files) {
      final ext = f.path.split('.').last.toLowerCase();
      extCounts[ext] = (extCounts[ext] ?? 0) + 1;
    }
    _log('Extensions found: $extCounts');

    final validFiles = files.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return _supportedExts.contains(ext);
    }).toList();

    _log('Valid image files (after filter): ${validFiles.length}');
    if (validFiles.isNotEmpty) {
      _log('First 3 files:');
      for (final f in validFiles.take(3)) {
        _log('  ${f.path}  (exists=${f.existsSync()})');
      }
    }

    if (validFiles.isEmpty) {
      _log('No valid files — returning early');
      isScanning = false;
      notifyListeners();
      return;
    }

    Map<String, LensGroup> groupMap = {};

    try {
      final exe = await _getExifToolExecutable();
      _log('ExifTool exe: $exe');

      // Write file paths to a temp argfile to bypass Windows 8191-char limit
      final tempDir = await getTemporaryDirectory();
      final argFile = File(
          '${tempDir.path}/lens_scan_${DateTime.now().millisecondsSinceEpoch}.txt');
      await argFile.writeAsString(
        validFiles.map((f) => f.path).join('\n'),
        flush: true,
      );
      _log('Argfile: ${argFile.path}  (${validFiles.length} paths)');

      // Flags go directly as args; file list comes from -@ argfile
      final result = await Process.run(exe, [
        '-FocalLength',
        '-FNumber',
        '-n',
        '-csv',
        '-@',
        argFile.path,
      ]);

      // Cleanup temp file
      if (await argFile.exists()) await argFile.delete();

      _log('exitCode: ${result.exitCode}');
      _log('stdout (${result.stdout.toString().length} chars):');
      _log(result.stdout
          .toString()
          .substring(0, result.stdout.toString().length.clamp(0, 2000)));
      if (result.stderr.toString().isNotEmpty) {
        _log(
            'stderr: ${result.stderr.toString().substring(0, result.stderr.toString().length.clamp(0, 1000))}');
      }

      if (result.exitCode == 0 || result.exitCode == 1) {
        // exitCode 1 = minor warning but CSV is still valid
        final lines = result.stdout.toString().split('\n');
        _log('CSV rows (incl header): ${lines.length}');
        if (lines.length > 1) {
          final headers = _parseCsvLine(lines[0]);
          final fileIdx = headers.indexOf('SourceFile');
          final focalIdx = headers.indexOf('FocalLength');
          final fNumIdx = headers.indexOf('FNumber');
          _log(
              'CSV headers: $headers  fileIdx=$fileIdx focalIdx=$focalIdx fNumIdx=$fNumIdx');

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
          _log('Groups built: ${groupMap.length}');
        }
      } else {
        _log('ExifTool fatal (exit ${result.exitCode}) — no groups created');
        AppNotifier.error(
          'ExifTool failed (exit ${result.exitCode})',
          exception: result.stderr.toString().isNotEmpty ? result.stderr : null,
        );
      }
    } catch (e, st) {
      _log('EXCEPTION in scanFiles: $e');
      _log('Stack: $st');
      AppNotifier.error('Scan failed: ${_shortMsg(e)}', exception: e);
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
        if (Platform.isWindows) {
          try { await Process.run('attrib', ['-r', item.path]); } catch (_) {}
        }
        final tmpFile = File('${item.path}_exiftool_tmp');
        if (await tmpFile.exists()) {
          try {
            if (Platform.isWindows) {
              await Process.run('attrib', ['-r', tmpFile.path]);
            }
            await tmpFile.delete();
          } catch (_) {}
        }
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
      if (result.exitCode == 0) {
        _log('ExifTool found in PATH');
        return 'exiftool';
      }
    } catch (e) {
      _log('ExifTool not in PATH: $e');
    }

    if (Platform.isWindows) {
      final cPath = 'C:\\exiftool\\exiftool.exe';
      if (await File(cPath).exists()) {
        _log('ExifTool found at C:\\exiftool\\exiftool.exe');
        return cPath;
      }
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(p.join(appDir.path, 'exiftool.exe'));
      if (!(await exeFile.exists())) {
        _log('Extracting exiftool.exe to ${exeFile.path}');
        final data = await rootBundle.load('assets/bin/exiftool.exe');
        final bytes = data.buffer.asUint8List();
        await exeFile.writeAsBytes(bytes);
      }
      _log('ExifTool at appDir: ${exeFile.path}');
      return exeFile.path;
    } catch (e) {
      _log('ExifTool fallback failed: $e');
      return 'exiftool';
    }
  }
}
