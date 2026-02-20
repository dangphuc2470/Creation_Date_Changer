import 'dart:io';
import 'package:path/path.dart' as p;

class FileModifier {
  /// Modify file creation and modification dates.
  /// Note: Dart's File API only allows modifying the last modified/accessed exact time easily.
  /// For exact "Creation Date" on Windows/macOS/Linux natively without FFI, we use the accessed time as a proxy, 
  /// or fall back to pure shell commands for actual creation dates.
  static Future<bool> changeFileDates(String path, DateTime newDate) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;

      // Set last modified/accessed (Dart's limitation for creation date)
      await file.setLastModified(newDate);
      await file.setLastAccessed(newDate);
      
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Change filename
  static Future<String?> changeFilename(String oldPath, String newNameTemplate, DateTime date, int sequenceNum) async {
    try {
      final file = File(oldPath);
      if (!await file.exists()) return null;

      final directory = p.dirname(oldPath);
      final extension = p.extension(oldPath);
      
      // Parse template, replace <dateformat> and [nnnn]
      // Assume a template like "IMG_<yyyyMMdd_HHmmss>_[nnnn]"
      String newName = newNameTemplate;
      
      // 1. Replce Date
      final dateRegex = RegExp(r'<([^>]+)>');
      final match = dateRegex.firstMatch(newName);
      if (match != null) {
        final formatStr = match.group(1)!;
        // Simple manual format mapping since DateFormat needs initialization
        // We will just replace common patterns
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

      // 2. Replace Sequence
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
    } catch (e) {
      return null;
    }
  }
}
