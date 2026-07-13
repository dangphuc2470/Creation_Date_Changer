import 'dart:io';
import 'package:xml/xml.dart';
import '../models/location_point.dart';

/// Service to parse GPX files
class GpxParser {
  /// Parse a GPX file and extract location points
  static Future<List<LocationPoint>> parseFile(String filePath) async {
    final file = File(filePath);
    final xmlString = await file.readAsString();
    
    final document = XmlDocument.parse(xmlString);
    final List<LocationPoint> points = [];
    
    // Find all track points
    final trkpts = document.findAllElements('trkpt');
    
    for (final trkpt in trkpts) {
      try {
        final lat = double.parse(trkpt.getAttribute('lat')!);
        final lon = double.parse(trkpt.getAttribute('lon')!);
        
        // Get time
        final timeElement = trkpt.findElements('time').firstOrNull;
        if (timeElement == null) continue;
        final time = DateTime.parse(timeElement.innerText);
        
        // Get elevation (optional)
        final eleElement = trkpt.findElements('ele').firstOrNull;
        final elevation = eleElement != null 
            ? double.tryParse(eleElement.innerText) 
            : null;
        
        points.add(LocationPoint.fromGpx(
          lat: lat,
          lon: lon,
          time: time,
          ele: elevation,
        ));
      } catch (e) {
        // Skip malformed points
        continue;
      }
    }
    
    // Sort by timestamp
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    return points;
  }
}
