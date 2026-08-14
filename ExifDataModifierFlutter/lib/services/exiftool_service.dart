import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared helper that locates the ExifTool executable.
///
/// Resolution order:
///   1. `exiftool` / `exiftool.exe` already in PATH
///   2. Sibling of the running executable (CMake deploy target)
///   3. `C:\exiftool\exiftool.exe` (standard Windows install)
///   4. Extracted from bundled asset `assets/bin/exiftool.exe` → app support dir
class ExifToolService {
  ExifToolService._();

  static String? _cachedPath;

  /// Returns the path (or command name) to use when invoking ExifTool.
  static Future<String> getExecutable() async {
    if (_cachedPath != null) return _cachedPath!;

    // 1. PATH
    try {
      final result = await Process.run('exiftool', ['-ver']);
      if (result.exitCode == 0) {
        _cachedPath = 'exiftool';
        return _cachedPath!;
      }
    } catch (_) {}

    if (Platform.isWindows) {
      // 2. Sibling of running executable
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final candidate = File(p.join(exeDir.path, 'exiftool.exe'));
        if (await candidate.exists()) {
          _cachedPath = candidate.path;
          return _cachedPath!;
        }
      } catch (_) {}

      // 3. Standard install location
      const standardPath = r'C:\exiftool\exiftool.exe';
      if (await File(standardPath).exists()) {
        _cachedPath = standardPath;
        return _cachedPath!;
      }
    }

    // 4. Extract from bundled asset
    try {
      final appDir = await getApplicationSupportDirectory();
      final exeFile = File(p.join(appDir.path, 'exiftool.exe'));
      if (!await exeFile.exists()) {
        final data = await rootBundle.load('assets/bin/exiftool.exe');
        final bytes = data.buffer.asUint8List();
        await exeFile.writeAsBytes(bytes);
      }
      _cachedPath = exeFile.path;
      return _cachedPath!;
    } catch (_) {}

    // Fallback – might not work, but let the caller handle the error
    _cachedPath = 'exiftool';
    return _cachedPath!;
  }

  /// Formats a [DateTime] as the string ExifTool expects: `YYYY:MM:DD HH:MM:SS`
  static String formatDateTime(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}:'
      '${dt.month.toString().padLeft(2, '0')}:'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  /// Writes EXIF date tags to a single file using ExifTool.
  ///
  /// Tags written:
  ///   - `DateTimeOriginal`  (Date Taken / shot time)
  ///   - `CreateDate`        (alias: DateTimeDigitized)
  ///   - `ModifyDate`        (last modified in EXIF header)
  ///
  /// Returns `true` on success.
  static Future<bool> writeExifDates(String filePath, DateTime date) async {
    try {
      final exe = await getExecutable();
      final dateStr = formatDateTime(date);

      // Remove ReadOnly attribute if present on Windows so ExifTool can edit file
      if (Platform.isWindows) {
        try { await Process.run('attrib', ['-r', filePath]); } catch (_) {}
      }

      // Clean up any stale temp file from previous interrupted runs
      final tmpFile = File('${filePath}_exiftool_tmp');
      if (await tmpFile.exists()) {
        try {
          if (Platform.isWindows) {
            await Process.run('attrib', ['-r', tmpFile.path]);
          }
          await tmpFile.delete();
        } catch (_) {}
      }

      final result = await Process.run(exe, [
        '-DateTimeOriginal=$dateStr',
        '-CreateDate=$dateStr',
        '-ModifyDate=$dateStr',
        '-overwrite_original',
        filePath,
      ]);

      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Batch-writes EXIF date tags for multiple files using a single ExifTool
  /// process (much faster than calling it per-file).
  ///
  /// [entries] maps file path → desired [DateTime].
  ///
  /// Returns the number of files successfully processed.
  static Future<int> writeExifDatesBatch(
    Map<String, DateTime> entries, {
    void Function(int processed, int total)? onProgress,
  }) async {
    if (entries.isEmpty) return 0;

    try {
      final exe = await getExecutable();
      final tempDir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final csvFile = File(p.join(tempDir.path, 'exif_dates_$ts.csv'));
      final argFile = File(p.join(tempDir.path, 'exif_args_$ts.txt'));

      // Build a CSV that ExifTool can read with -csv flag
      final csvBuf = StringBuffer();
      csvBuf.writeln('SourceFile,DateTimeOriginal,CreateDate,ModifyDate');
      for (final entry in entries.entries) {
        final escaped = entry.key.replaceAll('"', '""');
        final dateStr = formatDateTime(entry.value);
        csvBuf.writeln('"$escaped","$dateStr","$dateStr","$dateStr"');
      }

      // Build argfile (one path per line) for -@ flag
      final argBuf = StringBuffer();
      for (final filePath in entries.keys) {
        // Remove ReadOnly attribute if present on Windows so ExifTool can edit file
        if (Platform.isWindows) {
          try { await Process.run('attrib', ['-r', filePath]); } catch (_) {}
        }

        // Clean up any stale temp file from previous interrupted runs
        final tmpFile = File('${filePath}_exiftool_tmp');
        if (await tmpFile.exists()) {
          try {
            if (Platform.isWindows) {
              await Process.run('attrib', ['-r', tmpFile.path]);
            }
            await tmpFile.delete();
          } catch (_) {}
        }

        argBuf.writeln(filePath);
      }

      await csvFile.writeAsString(csvBuf.toString(), flush: true);
      await argFile.writeAsString(argBuf.toString(), flush: true);

      final process = await Process.start(exe, [
        '-progress',
        '-csv=${csvFile.path}',
        '-overwrite_original',
        '-@',
        argFile.path,
      ]);

      int processed = 0;
      final total = entries.length;
      final progressRe = RegExp(r'\[\s*(\d+)/\s*(\d+)\]');

      // Drain stdout so OS pipe buffer does not deadlock on Windows
      process.stdout.listen((_) {});

      // ExifTool writes progress to stderr
      process.stderr.transform(const SystemEncoding().decoder).listen((data) {
        final matches = progressRe.allMatches(data);
        for (final m in matches) {
          final cur = int.tryParse(m.group(1) ?? '');
          if (cur != null && cur > processed) {
            processed = cur;
            onProgress?.call(processed, total);
          }
        }
      });

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );

      // Clean up temp files
      try {
        await csvFile.delete();
        await argFile.delete();
      } catch (_) {}

      return exitCode == 0 ? total : 0;
    } catch (_) {
      return 0;
    }
  }
}
