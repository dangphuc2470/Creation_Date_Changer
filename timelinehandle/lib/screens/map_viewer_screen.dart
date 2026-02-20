import 'package:flutter/material.dart';

class MapViewerScreen extends StatefulWidget {
  const MapViewerScreen({super.key});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map, size: 64),
          SizedBox(height: 16),
          Text('Map Viewer'),
          SizedBox(height: 8),
          Text('Select a date from Location Manager to view on map'),
        ],
      ),
    );
  }
}
