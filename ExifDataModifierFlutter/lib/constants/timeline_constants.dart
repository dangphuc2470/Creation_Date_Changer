import 'package:flutter/material.dart';

class TimelineConstants {
  // Theme & Colors
  static const Color timelineAxisColor =
      Color(0xFF1A73E8); // Classic blue timeline line
  static const Color stayPointIconColor =
      Color(0xFF795548); // Brown place icon color
  static const Color defaultRouteColor =
      Color(0xFF0D47A1); // Default map route color (dark blue)
  static const Color activeRouteColor =
      Color(0xFF0D47A1); // Selected day map route color (dark blue)
  static const Color editRouteColor =
      Colors.orange; // Edit mode map route color

  // State Highlight Colors (Material Expressive Colors)
  static final Color originalStateColor =
      Colors.grey.shade400; // Grey for original/unedited
  static final Color editedStateColor =
      Colors.blue.shade300; // Blue for manually edited
  static final Color snappedStateColor =
      Colors.green.shade300; // Green for snapped to roads

  // State Text/Cell Highlight Colors (Material Expressive Colors)
  static final Color originalCellBg = Colors.grey.shade200;
  static final Color originalCellText = Colors.grey.shade800;
  static final Color editedCellBg = Colors.blue.shade100;
  static final Color editedCellText = const Color.fromARGB(255, 43, 47, 54);
  static final Color snappedCellBg = Colors.green.shade100;
  static final Color snappedCellText = Colors.green.shade900;

  // Sidebar List Dimensions & Thickness
  static const double timelineLineThickness =
      12.0; // Thickness of the vertical timeline line
  static const double timelineDotDiameter =
      12.0; // Diameter of the stay point dot circle
  static const double iconColumnWidth = 44.0; // Width of the icon column
  static const double lineColumnWidth = 20.0; // Width of the line column

  // Map Polyline Stroke Widths
  static const double polylineStrokeWidthEditing =
      5.0; // Edit mode active polyline
  static const double polylineStrokeWidthSelected =
      5.5; // Bold selected route segment
  static const double polylineStrokeWidthUnselected =
      3.5; // Faded unselected route segment
  static const double polylineStrokeWidthDefault = 4.5; // Normal route segments
  static const double polylineStrokeWidthInactive =
      3.0; // Other days' inactive routes (grey)

  // Clustering Configuration
  static const double stayPointDistanceThreshold =
      70.0; // Max distance in meters to cluster stay point
  static const Duration stayPointDurationThreshold = Duration(
      minutes: 3); // Default duration threshold to cluster stay point (3 mins)
}
