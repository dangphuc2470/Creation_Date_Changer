class DateExtractor {
  /// Extracts a DateTime from a filename using a given format mask.
  /// Example:
  /// Filename: "IMG_20240606_130614_A02BFA00.JPG"
  /// Format: "****yyyyMMdd*HHmmss"
  /// Returns DateTime(2024, 6, 6, 13, 6, 14)
  static DateTime? extractDate(String filename, String formatMask) {
    try {
      // Create a map to store the position of each date part
      Map<String, int> formatIndices = {};
      final parts = ['yyyy', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss'];
      
      for (var part in parts) {
        if (formatMask.contains(part)) {
          formatIndices[part] = formatMask.indexOf(part);
        }
      }

      // If no valid format parts found
      if (formatIndices.isEmpty) return null;

      // Extract parts by their indices and length
      int? year, month, day, hour, minute, second;
      
      // We go through the found indices and parse from filename
      formatIndices.forEach((part, index) {
        if (index + part.length <= filename.length) {
          final strValue = filename.substring(index, index + part.length);
          final value = int.tryParse(strValue);
          
          if (value != null) {
            switch (part) {
              case 'yyyy':
              case 'yy':
                year = part == 'yy' ? 2000 + value : value;
                break;
              case 'MM':
                month = value;
                break;
              case 'dd':
                day = value;
                break;
              case 'HH':
                hour = value;
                break;
              case 'mm':
                minute = value;
                break;
              case 'ss':
                second = value;
                break;
            }
          }
        }
      });

      if (year != null && month != null && day != null) {
        return DateTime(year!, month!, day!, hour ?? 0, minute ?? 0, second ?? 0);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
