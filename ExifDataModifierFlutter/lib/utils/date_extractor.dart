/// DateExtractor - parses a DateTime from a filename using a format mask.
///
/// ## Format Mask Syntax
///
/// | Token | Meaning                          |
/// |-------|----------------------------------|
/// | *     | Wildcard – matches any number of characters (auto-search mode) |
/// | yyyy  | 4-digit year                     |
/// | yy    | 2-digit year (prefixed with 2000)|
/// | MM    | 2-digit month (01-12)            |
/// | dd    | 2-digit day   (01-31)            |
/// | HH    | 2-digit hour  (00-23)            |
/// | mm    | 2-digit minute (00-59)           |
/// | ss    | 2-digit second (00-59)           |
/// | other | Literal character – must match exactly |
///
/// ## Examples
///
/// ```
/// Mask: *yyyyMMdd*HHmmss
/// File: 6D_20240606_130614.jpg   → DateTime(2024, 6, 6, 13, 6, 14) ✅
/// File: 5D2_20240606_130614.jpg  → DateTime(2024, 6, 6, 13, 6, 14) ✅
/// File: IMG_20240606_130614_A02BFA00.jpg → same ✅
///
/// Mask: yyyyMMdd_HHmmss
/// File: 20240606_130614.jpg → DateTime(2024, 6, 6, 13, 6, 14) ✅
/// ```
class DateExtractor {
  /// Extracts a [DateTime] from [filename] using [formatMask].
  static DateTime? extractDate(String filename, String formatMask) {
    try {
      // Remove file extension
      final lastDot = filename.lastIndexOf('.');
      final name = lastDot != -1 ? filename.substring(0, lastDot) : filename;

      final segments = _parseMask(formatMask);
      final captured = _match(name, 0, segments, 0);
      if (captured == null) return null;

      final year = captured['yyyy'] ??
          (captured['yy'] != null ? 2000 + captured['yy']! : null);
      final month = captured['MM'];
      final day = captured['dd'];

      if (year == null || month == null || day == null) return null;

      return DateTime(
        year,
        month,
        day,
        captured['HH'] ?? 0,
        captured['mm'] ?? 0,
        captured['ss'] ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Tries to auto-detect a format mask from [filename].
  ///
  /// Scans for an 8-digit block (`yyyyMMdd`) or separated 3-run date (`yyyy-MM-dd`, `yyyy_MM_dd`, etc.),
  /// and optionally a 6-digit time (`HHmmss`) or separated time (`HH-mm-ss`, `HH.mm.ss`, etc.).
  /// If [useWildcardsForSeparators] is true, literal separators are replaced with `*` wildcards.
  static String? autoDetectMask(String filename, {bool useWildcardsForSeparators = true}) {
    try {
      final lastDot = filename.lastIndexOf('.');
      final name = lastDot != -1 ? filename.substring(0, lastDot) : filename;

      // Collect all runs of digits with their start/end positions
      final runs = <_DigitRun>[];
      int? runStart;
      for (int i = 0; i <= name.length; i++) {
        final isDigit = i < name.length && _isDigitChar(name[i]);
        if (isDigit && runStart == null) {
          runStart = i;
        } else if (!isDigit && runStart != null) {
          runs.add(_DigitRun(runStart, i, name.substring(runStart, i)));
          runStart = null;
        }
      }

      int dateStart = -1;
      int dateEnd = -1;
      String datePattern = '';

      int timeStart = -1;
      String timePattern = '';
      String dateToTimeSep = '';

      // 1. Try to find date block
      for (int i = 0; i < runs.length; i++) {
        final r = runs[i];

        // Case A: 8-digit run (yyyyMMdd)
        if (r.value.length == 8) {
          final y = int.parse(r.value.substring(0, 4));
          final mo = int.parse(r.value.substring(4, 6));
          final d = int.parse(r.value.substring(6, 8));
          if (_isValidDate(y, mo, d)) {
            dateStart = r.start;
            dateEnd = r.end;
            datePattern = 'yyyyMMdd';
            break;
          }
        }

        // Case B: 3 consecutive runs (yyyy - MM - dd)
        if (i + 2 < runs.length) {
          final r1 = runs[i];
          final r2 = runs[i + 1];
          final r3 = runs[i + 2];

          if (r1.value.length == 4 && r2.value.length == 2 && r3.value.length == 2) {
            final sep1 = name.substring(r1.end, r2.start);
            final sep2 = name.substring(r2.end, r3.start);

            if (sep1 == sep2 && (sep1 == '-' || sep1 == '_' || sep1 == '.' || sep1 == ' ')) {
              final y = int.parse(r1.value);
              final mo = int.parse(r2.value);
              final d = int.parse(r3.value);
              if (_isValidDate(y, mo, d)) {
                dateStart = r1.start;
                dateEnd = r3.end;
                datePattern = useWildcardsForSeparators
                    ? 'yyyy*MM*dd'
                    : 'yyyy${sep1}MM${sep2}dd';
                break;
              }
            }
          }
        }
      }

      if (dateStart == -1) return null;

      // 2. Try to find time block AFTER date block
      for (int i = 0; i < runs.length; i++) {
        final r = runs[i];
        if (r.start < dateEnd) continue; // Time must come after date

        // Case A: 6-digit run (HHmmss)
        if (r.value.length == 6) {
          final h = int.parse(r.value.substring(0, 2));
          final m = int.parse(r.value.substring(2, 4));
          final s = int.parse(r.value.substring(4, 6));
          if (_isValidTime(h, m, s)) {
            timeStart = r.start;
            timePattern = 'HHmmss';
            dateToTimeSep = useWildcardsForSeparators
                ? '*'
                : name.substring(dateEnd, timeStart);
            break;
          }
        }

        // Case B: 3 consecutive runs (HH - mm - ss)
        if (i + 2 < runs.length) {
          final r1 = runs[i];
          final r2 = runs[i + 1];
          final r3 = runs[i + 2];

          if (r1.value.length == 2 && r2.value.length == 2 && r3.value.length == 2) {
            final sep1 = name.substring(r1.end, r2.start);
            final sep2 = name.substring(r2.end, r3.start);

            if (sep1 == sep2 && (sep1 == '-' || sep1 == '_' || sep1 == '.' || sep1 == ':')) {
              final h = int.parse(r1.value);
              final m = int.parse(r2.value);
              final s = int.parse(r3.value);
              if (_isValidTime(h, m, s)) {
                timeStart = r1.start;
                timePattern = useWildcardsForSeparators
                    ? 'HH*mm*ss'
                    : 'HH${sep1}mm${sep2}ss';
                dateToTimeSep = useWildcardsForSeparators
                    ? '*'
                    : name.substring(dateEnd, timeStart);
                break;
              }
            }
          }
        }
      }

      final buf = StringBuffer();
      if (dateStart > 0) buf.write('*'); // wildcard prefix
      buf.write(datePattern);

      if (timeStart != -1) {
        buf.write(dateToTimeSep);
        buf.write(timePattern);
      }

      return buf.toString();
    } catch (_) {
      return null;
    }
  }



  static bool _isValidDate(int y, int mo, int d) {
    return y >= 1970 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31;
  }

  static bool _isValidTime(int h, int m, int s) {
    return h >= 0 && h <= 23 && m >= 0 && m <= 59 && s >= 0 && s <= 59;
  }




  // ---------------------------------------------------------------------------
  // Internal matching engine
  // ---------------------------------------------------------------------------

  /// Recursive backtracking matcher.
  ///
  /// Returns a map of captured date components on success, null on failure.
  /// The returned map is built bottom-up so callers don't need to worry about
  /// restoring state on backtrack.
  static Map<String, int>? _match(
    String s,
    int si,
    List<_Segment> segs,
    int pi,
  ) {
    // All segments consumed → success
    if (pi == segs.length) return {};

    final seg = segs[pi];

    if (seg is _Wildcard) {
      // Try wildcard consuming 0, 1, 2, … characters
      for (int len = 0; si + len <= s.length; len++) {
        final result = _match(s, si + len, segs, pi + 1);
        if (result != null) return result;
      }
      return null;
    }

    if (seg is _DateComponent) {
      if (si + seg.length > s.length) return null;
      final substr = s.substring(si, si + seg.length);
      final val = int.tryParse(substr);
      if (val == null || !_isValidComponent(seg.key, val)) return null;
      final result = _match(s, si + seg.length, segs, pi + 1);
      if (result == null) return null;
      result[seg.key] = val; // add captured value on the way back up
      return result;
    }

    if (seg is _Literal) {
      if (!s.startsWith(seg.text, si)) return null;
      return _match(s, si + seg.text.length, segs, pi + 1);
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Mask parser
  // ---------------------------------------------------------------------------

  static List<_Segment> _parseMask(String mask) {
    final segs = <_Segment>[];
    int i = 0;

    while (i < mask.length) {
      // Wildcard: one or more '*' → single wildcard segment
      if (mask[i] == '*') {
        while (i < mask.length && mask[i] == '*') { i++; }
        segs.add(_Wildcard());
        continue;
      }

      // Date/time tokens – order matters (yyyy before yy)
      bool matched = false;
      for (final token in _tokens) {
        if (mask.startsWith(token, i)) {
          segs.add(_DateComponent(token, token.length));
          i += token.length;
          matched = true;
          break;
        }
      }
      if (matched) continue;

      // Literal character – merge with preceding literal if possible
      if (segs.isNotEmpty && segs.last is _Literal) {
        (segs.last as _Literal).text += mask[i];
      } else {
        segs.add(_Literal(mask[i]));
      }
      i++;
    }

    return segs;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static const _tokens = ['yyyy', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss'];

  static bool _isValidComponent(String key, int val) {
    switch (key) {
      case 'yyyy': return val >= 1970 && val <= 2100;
      case 'yy':   return val >= 0   && val <= 99;
      case 'MM':   return val >= 1   && val <= 12;
      case 'dd':   return val >= 1   && val <= 31;
      case 'HH':   return val >= 0   && val <= 23;
      case 'mm':   return val >= 0   && val <= 59;
      case 'ss':   return val >= 0   && val <= 59;
      default:     return true;
    }
  }

  static bool _isDigitChar(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
}

// ---------------------------------------------------------------------------
// Segment types
// ---------------------------------------------------------------------------

abstract class _Segment {}

class _Wildcard extends _Segment {}

class _DateComponent extends _Segment {
  final String key;
  final int length;
  _DateComponent(this.key, this.length);
}

class _Literal extends _Segment {
  String text;
  _Literal(this.text);
}

class _DigitRun {
  final int start;
  final int end;
  final String value;
  _DigitRun(this.start, this.end, this.value);
}
