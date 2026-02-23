import 'package:flutter/material.dart';
import 'screens/import_export_screen.dart';
import 'screens/location_manager_screen.dart';
import 'screens/map_viewer_screen.dart';
import 'screens/settings_screen.dart';
import 'models/location_point.dart';
import 'services/location_manager.dart';

void main() {
  runApp(const TimelineHandlerApp());
}

class TimelineHandlerApp extends StatelessWidget {
  const TimelineHandlerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Timeline Handler',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
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

  // Persistent state for Location Manager
  List<DateInfo> _allDates = [];
  String? _lastLoadedPath;

  // Persistent state for Map Viewer
  final Map<String, List<LocationPoint>> _activePaths =
      {}; // filePath -> points
  final Map<String, Color> _pathColors = {}; // filePath -> color

  final List<Color> _colorPalette = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.indigo,
    Colors.pink,
    Colors.amber,
    Colors.cyan,
  ];

  void _onDatesLoaded(List<DateInfo> newDates, String path) {
    setState(() {
      _lastLoadedPath = path;
      final Map<String, DateInfo> merged = {
        for (var d in _allDates) d.filePath: d,
      };

      for (var d in newDates.reversed) {
        merged[d.filePath] = d;
      }

      _allDates = merged.values.toList();
      _allDates.sort((a, b) => b.date.compareTo(a.date));
    });
  }

  void _togglePathVisibility(DateInfo dateInfo, List<LocationPoint> points) {
    setState(() {
      if (_activePaths.containsKey(dateInfo.filePath)) {
        _activePaths.remove(dateInfo.filePath);
        _pathColors.remove(dateInfo.filePath);
      } else {
        _activePaths[dateInfo.filePath] = points;
        _pathColors[dateInfo.filePath] =
            _colorPalette[_activePaths.length % _colorPalette.length];
      }
    });
  }

  void _refreshSettings() {
    setState(() {
      // Trigger rebuild to update consumers of SettingsService
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      const ImportExportScreen(),
      LocationManagerScreen(
        dates: _allDates,
        loadedPath: _lastLoadedPath,
        onDatesLoaded: _onDatesLoaded,
        activePathIds: _activePaths.keys.toSet(),
        onTogglePath: _togglePathVisibility,
      ),
      MapViewerScreen(
        paths: _activePaths,
        pathColors: _pathColors,
      ),
      SettingsScreen(onSettingsChanged: _refreshSettings),
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Icon(Icons.auto_fix_high, size: 32, color: Colors.blue),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.import_export),
                label: Text('Import'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: Text('Manage'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: Text('Map'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: screens,
            ),
          ),
        ],
      ),
    );
  }
}
