import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state_provider.dart';
import 'providers/change_date_provider.dart';
import 'providers/change_filename_provider.dart';
import 'providers/batch_geotag_provider.dart';
import 'providers/geotag_provider.dart';
import 'providers/lens_metadata_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/batch_geotag_screen.dart';
import 'screens/change_date_screen.dart';
import 'screens/change_filename_screen.dart';
import 'screens/geotag_screen.dart';
import 'screens/import_export_screen.dart';
import 'screens/location_manager_screen.dart';
import 'screens/map_viewer_screen.dart';
import 'screens/lens_metadata_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_notifier.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
        ChangeNotifierProvider(create: (_) => ChangeDateProvider()),
        ChangeNotifierProvider(create: (_) => ChangeFilenameProvider()),
        ChangeNotifierProvider(create: (_) => GeotagProvider()),
        ChangeNotifierProvider(create: (_) => BatchGeotagProvider()),
        ChangeNotifierProvider(create: (_) => LensMetadataProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: const ExifModifierApp(),
    ),
  );
}

class ExifModifierApp extends StatelessWidget {
  const ExifModifierApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Exif Data Modifier',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const _NotifListener(child: MainLayoutScreen()),
    );
  }
}

/// Wraps the root screen and listens to [AppNotifier] to show SnackBars.
class _NotifListener extends StatefulWidget {
  const _NotifListener({required this.child});
  final Widget child;

  @override
  State<_NotifListener> createState() => _NotifListenerState();
}

class _NotifListenerState extends State<_NotifListener> {
  @override
  void initState() {
    super.initState();
    AppNotifier.notifier.addListener(_onNotif);
  }

  @override
  void dispose() {
    AppNotifier.notifier.removeListener(_onNotif);
    super.dispose();
  }

  void _onNotif() {
    final notif = AppNotifier.notifier.value;
    if (notif == null || !mounted) return;

    final (bg, icon) = switch (notif.type) {
      AppNotifType.error => (const Color(0xFFC62828), Icons.error_outline),
      AppNotifType.warning => (
          const Color(0xFFE65100),
          Icons.warning_amber_rounded
        ),
      AppNotifType.success => (
          const Color(0xFF2E7D32),
          Icons.check_circle_outline
        ),
      AppNotifType.info => (const Color(0xFF4527A0), Icons.info_outline),
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bg,
        duration: notif.type == AppNotifType.error
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                notif.message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        action: notif.detail != null
            ? SnackBarAction(
                label: 'Details',
                textColor: Colors.white70,
                onPressed: () => _showDetailDialog(notif),
              )
            : null,
      ),
    );
  }

  void _showDetailDialog(AppNotif notif) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(notif.message),
        content: SingleChildScrollView(
          child: SelectableText(
            notif.detail ?? '',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MainLayoutScreen extends StatelessWidget {
  const MainLayoutScreen({super.key});

  final List<Widget> _pages = const [
    ChangeDateScreen(),
    ChangeFilenameScreen(),
    GeotagScreen(),
    BatchGeotagScreen(),
    ImportExportScreen(),
    LocationManagerScreen(),
    MapViewerScreen(),
    LensMetadataScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 600;
    final appState = context.watch<AppStateProvider>();

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: appState.currentIndex,
              onDestinationSelected: appState.setIndex,
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.date_range),
                  label: Text('Change Date'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.edit_document),
                  label: Text('Rename'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.pin_drop),
                  label: Text('Geotag'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.photo_library_outlined),
                  label: Text('Batch Geotag'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.import_export),
                  label: Text('Timeline Import'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.folder_open),
                  label: Text('Timeline Manage'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.map),
                  label: Text('Timeline Map'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.camera),
                  label: Text('Lens'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings),
                  label: Text('Settings'),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: _pages[appState.currentIndex],
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: _pages[appState.currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: appState.currentIndex,
        onDestinationSelected: appState.setIndex,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.date_range),
            label: 'Change Date',
          ),
          NavigationDestination(
            icon: Icon(Icons.edit_document),
            label: 'Rename',
          ),
          NavigationDestination(
            icon: Icon(Icons.pin_drop),
            label: 'Geotag',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            label: 'Batch Geotag',
          ),
          NavigationDestination(
            icon: Icon(Icons.import_export),
            label: 'Timeline Import',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_open),
            label: 'Timeline Manage',
          ),
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'Timeline Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.camera),
            label: 'Lens',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
