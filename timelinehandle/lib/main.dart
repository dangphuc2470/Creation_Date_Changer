import 'package:flutter/material.dart';
import 'screens/import_export_screen.dart';
import 'screens/location_manager_screen.dart';
import 'screens/map_viewer_screen.dart';

void main() {
  runApp(const TimelineHandlerApp());
}

class TimelineHandlerApp extends StatelessWidget {
  const TimelineHandlerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Timeline Handler',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    ImportExportScreen(),
    LocationManagerScreen(),
    MapViewerScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timeline Handler'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.import_export),
            label: 'Import & Export',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder),
            label: 'Location Manager',
          ),
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'Map Viewer',
          ),
        ],
      ),
    );
  }
}
