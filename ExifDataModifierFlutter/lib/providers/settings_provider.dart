import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lens_template.dart';

class SettingsProvider extends ChangeNotifier {
  late SharedPreferences _prefs;
  bool _isLoaded = false;

  // Preferences
  String defaultChangeDateFormat = '****yyyyMMdd*HHmmss';
  String defaultRenameFormat = 'IMG_<yyyyMMdd_HHmmss>_[nnnn]';
  String mapProvider = 'google_roadmap';
  List<LensTemplate> lensTemplates = [];

  bool get isLoaded => _isLoaded;

  SettingsProvider() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    defaultChangeDateFormat = _prefs.getString('defaultChangeDateFormat') ?? '****yyyyMMdd*HHmmss';
    defaultRenameFormat = _prefs.getString('defaultRenameFormat') ?? 'IMG_<yyyyMMdd_HHmmss>_[nnnn]';
    mapProvider = _prefs.getString('mapProvider') ?? 'google_roadmap';
    
    final lensesJson = _prefs.getStringList('lensTemplates');
    if (lensesJson != null) {
      lensTemplates = lensesJson.map((e) => LensTemplate.fromJson(e)).toList();
    } else {
      // Add a default template from user's example
      lensTemplates = [
        LensTemplate(id: 'default1', name: 'Carl Zeiss Jena 135mm f/3.5', make: 'Carl Zeiss', model: 'Carl Zeiss Jena 135mm f/3.5', focalLength: 135.0, fNumber: 3.5),
      ];
    }
    
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> addLensTemplate(LensTemplate template) async {
    lensTemplates.add(template);
    await _saveLensTemplates();
    notifyListeners();
  }

  Future<void> removeLensTemplate(String id) async {
    lensTemplates.removeWhere((element) => element.id == id);
    await _saveLensTemplates();
    notifyListeners();
  }

  Future<void> _saveLensTemplates() async {
    final list = lensTemplates.map((e) => e.toJson()).toList();
    await _prefs.setStringList('lensTemplates', list);
  }

  Future<void> updateChangeDateFormat(String val) async {
    defaultChangeDateFormat = val;
    await _prefs.setString('defaultChangeDateFormat', val);
    notifyListeners();
  }

  Future<void> updateRenameFormat(String val) async {
    defaultRenameFormat = val;
    await _prefs.setString('defaultRenameFormat', val);
    notifyListeners();
  }

  Future<void> updateMapProvider(String provider) async {
    mapProvider = provider;
    await _prefs.setString('mapProvider', provider);
    notifyListeners();
  }
}
