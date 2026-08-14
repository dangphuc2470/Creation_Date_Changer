import 'dart:io';
import 'package:path/path.dart' as p;

class FileModifier {
  // ── Single-file helpers (kept for backward compat) ─────────────────────────

  /// Modify file last-modified and last-accessed dates.
  static Future<bool> changeFileDates(String path, DateTime newDate) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      await file.setLastModified(newDate);
      await file.setLastAccessed(newDate);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Batch operations ────────────────────────────────────────────────────────

  /// Batch-sets `LastModified` + `LastAccessed` for all [entries] in parallel,
  /// then issues a single PowerShell call (Windows) to also set `CreationTime`.
  ///
  /// Returns a map of `path → success`.
  static Future<Map<String, bool>> changeFileDatesBatch(
    Map<String, DateTime> entries, {
    void Function(int processed, int total)? onProgress,
  }) async {
    if (entries.isEmpty) return {};

    final results = <String, bool>{};
    int processed = 0;
    final total = entries.length;

    // 1. Set LastModified + LastAccessed in parallel (fast Dart I/O)
    await Future.wait(entries.entries.map((e) async {
      try {
        final file = File(e.key);
        if (!await file.exists()) {
          results[e.key] = false;
          return;
        }
        await file.setLastModified(e.value);
        await file.setLastAccessed(e.value);
        results[e.key] = true;
      } catch (_) {
        results[e.key] = false;
      }
      onProgress?.call(++processed, total);
    }));

    // 2. Set CreationTime on Windows via a single PowerShell batch call.
    //    Dart's File API has no native API for creation time.
    if (Platform.isWindows) {
      await _batchSetWindowsCreationTime(entries);
    }

    return results;
  }

  /// Issues one PowerShell process to set CreationTime for all [entries].
  /// Much faster than spawning PowerShell per file.
  static Future<void> _batchSetWindowsCreationTime(
    Map<String, DateTime> entries,
  ) async {
    if (entries.isEmpty) return;
    try {
      // Build a compact PowerShell script:
      //   $d = @{ 'path1' = '2024-06-06 13:06:14'; ... }
      //   foreach ($kv in $d.GetEnumerator()) {
      //     (Get-Item $kv.Key).CreationTime = [DateTime]$kv.Value
      //   }
      final buf = StringBuffer();
      buf.write(r'$d = @{');
      bool first = true;
      for (final e in entries.entries) {
        if (!first) buf.write('; ');
        first = false;
        final escaped = e.key.replaceAll("'", "''");
        final dateStr = _psDate(e.value);
        buf.write("'$escaped'='$dateStr'");
      }
      buf.writeln('};');
      buf.writeln(
        r"foreach ($kv in $d.GetEnumerator()) { "
        r"Try { (Get-Item $kv.Key -EA Stop).CreationTime = [DateTime]$kv.Value } "
        r"Catch {} }",
      );

      await Process.run('powershell', ['-NoProfile', '-Command', buf.toString()]);
    } catch (_) {}
  }

  // ── Change filename ─────────────────────────────────────────────────────────

  /// Rename a file using a template like `IMG_<yyyyMMdd_HHmmss>_[nnnn]`.
  static Future<String?> changeFilename(
    String oldPath,
    String newNameTemplate,
    DateTime date,
    int sequenceNum,
  ) async {
    try {
      final file = File(oldPath);
      if (!await file.exists()) return null;

      final directory = p.dirname(oldPath);
      final extension = p.extension(oldPath);

      String newName = newNameTemplate;

      // 1. Replace <dateformat>
      final dateRegex = RegExp(r'<([^>]+)>');
      final match = dateRegex.firstMatch(newName);
      if (match != null) {
        final formatStr = match.group(1)!;
        final dateStr = formatStr
            .replaceAll('yyyy', date.year.toString().padLeft(4, '0'))
            .replaceAll('yy', (date.year % 100).toString().padLeft(2, '0'))
            .replaceAll('MM', date.month.toString().padLeft(2, '0'))
            .replaceAll('dd', date.day.toString().padLeft(2, '0'))
            .replaceAll('HH', date.hour.toString().padLeft(2, '0'))
            .replaceAll('mm', date.minute.toString().padLeft(2, '0'))
            .replaceAll('ss', date.second.toString().padLeft(2, '0'));
        newName = newName.replaceFirst('<$formatStr>', dateStr);
      }

      // 2. Replace [nnnn] sequence
      final seqRegex = RegExp(r'\[(n+)\]');
      final seqMatch = seqRegex.firstMatch(newName);
      if (seqMatch != null) {
        final nString = seqMatch.group(1)!;
        final seqStr = sequenceNum.toString().padLeft(nString.length, '0');
        newName = newName.replaceFirst('[$nString]', seqStr);
      }

      final newPath = p.join(directory, newName + extension);
      await file.rename(newPath);
      return newPath;
    } catch (_) {
      return null;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _psDate(DateTime dt) =>
      '${dt.year}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}
