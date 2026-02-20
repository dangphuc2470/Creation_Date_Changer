enum ExportMode {
  yearMonthDay,
  dateRange,
}

/// Configuration for exporting location data
class ExportConfig {
  final ExportMode mode;
  final DateTime? startDate;
  final DateTime endDate;
  final String outputPath;

  ExportConfig({
    required this.mode,
    this.startDate,
    DateTime? endDate,
    required this.outputPath,
  }) : endDate = endDate ?? DateTime.now();

  /// Get date range description
  String get dateRangeDescription {
    if (startDate == null) {
      return 'All data up to ${_formatDate(endDate)}';
    }
    return '${_formatDate(startDate!)} to ${_formatDate(endDate)}';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
