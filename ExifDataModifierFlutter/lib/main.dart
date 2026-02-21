import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state_provider.dart';
import 'providers/change_date_provider.dart';
import 'providers/change_filename_provider.dart';
import 'providers/geotag_provider.dart';
import 'providers/lens_metadata_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/change_date_screen.dart';
import 'screens/change_filename_screen.dart';
import 'screens/geotag_screen.dart';
import 'screens/lens_metadata_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
        ChangeNotifierProvider(create: (_) => ChangeDateProvider()),
        ChangeNotifierProvider(create: (_) => ChangeFilenameProvider()),
        ChangeNotifierProvider(create: (_) => GeotagProvider()),
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
      themeMode: ThemeMode.system, // Uses device settings to choose light/dark
      home: const MainLayoutScreen(),
    );
  }
}

class MainLayoutScreen extends StatelessWidget {
  const MainLayoutScreen({super.key});

  final List<Widget> _pages = const [
    ChangeDateScreen(),
    ChangeFilenameScreen(),
    GeotagScreen(),
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
                  icon: Icon(Icons.map),
                  label: Text('Geotag'),
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
            icon: Icon(Icons.map),
            label: 'Geotag',
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
