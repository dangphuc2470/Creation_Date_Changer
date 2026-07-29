import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lens_template.dart';
import '../models/favorite_road.dart';

class SettingsProvider extends ChangeNotifier {
  late SharedPreferences _prefs;
  bool _isLoaded = false;

  // Preferences
  String defaultChangeDateFormat = '****yyyyMMdd*HHmmss';
  String defaultRenameFormat = 'IMG_<yyyyMMdd_HHmmss>_[nnnn]';
  String mapProvider = 'google_roadmap';
  List<LensTemplate> lensTemplates = [];
  Map<String, String> lensMappings =
      {}; // Key: "focal_aperture", Value: "lensId"
  int geotagTimezone = 7;
  String routingProvider = 'osrm';
  String osrmProfile = 'bike'; // 'bike' (motorcycle/alleys), 'driving' (car), 'foot' (walk)
  String googleMapsApiKey = '';
  bool requireShiftToDrag = false;
  bool get requireCtrlToDrag => requireShiftToDrag;

  List<FavoriteRoad> favoriteRoads = [];

  bool get isLoaded => _isLoaded;

  SettingsProvider() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    defaultChangeDateFormat =
        _prefs.getString('defaultChangeDateFormat') ?? '****yyyyMMdd*HHmmss';
    defaultRenameFormat = _prefs.getString('defaultRenameFormat') ??
        'IMG_<yyyyMMdd_HHmmss>_[nnnn]';
    mapProvider = _prefs.getString('mapProvider') ?? 'google_roadmap';
    geotagTimezone = _prefs.getInt('geotagTimezone') ?? 7;
    routingProvider = _prefs.getString('routingProvider') ?? 'osrm';
    osrmProfile = _prefs.getString('osrmProfile') ?? 'bike';
    googleMapsApiKey = _prefs.getString('googleMapsApiKey') ?? '';
    requireShiftToDrag = _prefs.getBool('requireShiftToDrag') ??
        _prefs.getBool('requireCtrlToDrag') ??
        false;

    final favJson = _prefs.getStringList('favoriteRoads');
    if (favJson != null) {
      favoriteRoads = favJson.map((e) => FavoriteRoad.fromJson(e)).toList();
    }

    final lensesJson = _prefs.getStringList('lensTemplates');
    if (lensesJson != null) {
      lensTemplates = lensesJson.map((e) => LensTemplate.fromJson(e)).toList();
    } else {
      // Add default templates based on user's manual lenses
      lensTemplates = [
        LensTemplate(
            id: 'takumar300',
            name: 'Super-Takumar 300mm f/4',
            make: 'Asahi Pentax',
            model: 'Super-Takumar 300mm f/4',
            focalLength: 300.0,
            fNumber: 4.0),
        LensTemplate(
            id: 'czj135',
            name: 'Carl Zeiss Jena MC Sonnar 135mm f/3.5',
            make: 'Carl Zeiss Jena',
            model: 'Carl Zeiss Jena MC Sonnar 135mm f/3.5',
            focalLength: 135.0,
            fNumber: 3.5),
        LensTemplate(
            id: 'canon50stm',
            name: 'EF50mm f/1.8 STM',
            make: 'Canon',
            model: 'EF50mm f/1.8 STM',
            focalLength: 50.0,
            fNumber: 1.8),
        LensTemplate(
            id: 'canon70300is',
            name: 'EF70-300mm f/4-5.6 IS USM',
            make: 'Canon',
            model: 'EF70-300mm f/4-5.6 IS USM',
            focalLength: 70.0,
            fNumber: 4.0),
        LensTemplate(
            id: 'sigma2470macro',
            name: 'Sigma 24-70mm f/2.8 EX DG Macro',
            make: 'Sigma',
            model: 'Sigma 24-70mm f/2.8 EX DG Macro',
            focalLength: 24.0,
            fNumber: 2.8),
      ];
    }

    final mappingsJson = _prefs.getString('lensMappings');
    if (mappingsJson != null) {
      lensMappings = Map<String, String>.from(json.decode(mappingsJson));
    } else {
      // Default mapping for Carl Zeiss
      lensMappings = {'0.0_0.0': 'carlzeiss'};
    }

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> addLensTemplate(LensTemplate template) async {
    lensTemplates.add(template);
    await _saveLensTemplates();
    notifyListeners();
  }

  Future<void> updateLensTemplate(LensTemplate template) async {
    final index =
        lensTemplates.indexWhere((element) => element.id == template.id);
    if (index != -1) {
      lensTemplates[index] = template;
      await _saveLensTemplates();
      notifyListeners();
    }
  }

  Future<void> removeLensTemplate(String id) async {
    lensTemplates.removeWhere((element) => element.id == id);
    // Also remove any mappings pointing to this lens
    lensMappings.removeWhere((key, value) => value == id);
    await _saveLensTemplates();
    await _saveLensMappings();
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

  Future<void> updateGeotagTimezone(int tz) async {
    geotagTimezone = tz;
    await _prefs.setInt('geotagTimezone', tz);
    notifyListeners();
  }

  Future<void> updateLensMapping(String exifSignature, String? lensId) async {
    if (lensId == null) {
      lensMappings.remove(exifSignature);
    } else {
      lensMappings[exifSignature] = lensId;
    }
    await _saveLensMappings();
    notifyListeners();
  }

  Future<void> _saveLensMappings() async {
    await _prefs.setString('lensMappings', json.encode(lensMappings));
  }

  Future<void> updateRoutingProvider(String val) async {
    routingProvider = val;
    await _prefs.setString('routingProvider', val);
    notifyListeners();
  }

  Future<void> updateOsrmProfile(String val) async {
    osrmProfile = val;
    await _prefs.setString('osrmProfile', val);
    notifyListeners();
  }

  Future<void> updateGoogleMapsApiKey(String val) async {
    googleMapsApiKey = val;
    await _prefs.setString('googleMapsApiKey', val);
    notifyListeners();
  }

  Future<void> updateRequireShiftToDrag(bool val) async {
    requireShiftToDrag = val;
    await _prefs.setBool('requireShiftToDrag', val);
    notifyListeners();
  }

  Future<void> updateRequireCtrlToDrag(bool val) =>
      updateRequireShiftToDrag(val);

  Future<void> addFavoriteRoad(FavoriteRoad road) async {
    favoriteRoads.removeWhere((r) => r.id == road.id);
    favoriteRoads.insert(0, road);
    await _prefs.setStringList(
        'favoriteRoads', favoriteRoads.map((r) => r.toJson()).toList());
    notifyListeners();
  }

  Future<void> removeFavoriteRoad(String id) async {
    favoriteRoads.removeWhere((r) => r.id == id);
    await _prefs.setStringList(
        'favoriteRoads', favoriteRoads.map((r) => r.toJson()).toList());
    notifyListeners();
  }
}
