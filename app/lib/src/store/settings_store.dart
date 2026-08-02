import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../model/models.dart';

/// Persists server profiles and app settings via shared_preferences.
class SettingsStore {
  static const _kProfiles = 'profiles';
  static const _kSelected = 'selectedProfile';
  static const _kProxy = 'proxySettings';
  static const _kMode = 'mode';

  final SharedPreferences _prefs;
  SettingsStore(this._prefs);

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore(prefs);
  }

  List<ServerProfile> loadProfiles() {
    final raw = _prefs.getStringList(_kProfiles) ?? const [];
    return raw
        .map((s) => ServerProfile.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveProfiles(List<ServerProfile> profiles) async {
    await _prefs.setStringList(
        _kProfiles, profiles.map((p) => p.toJsonString()).toList());
  }

  String? get selectedProfileId => _prefs.getString(_kSelected);
  Future<void> setSelectedProfileId(String? id) async {
    if (id == null) {
      await _prefs.remove(_kSelected);
    } else {
      await _prefs.setString(_kSelected, id);
    }
  }

  ProxySettings loadProxySettings() {
    final s = _prefs.getString(_kProxy);
    if (s == null) return const ProxySettings();
    return ProxySettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> saveProxySettings(ProxySettings settings) async {
    await _prefs.setString(_kProxy, jsonEncode(settings.toJson()));
  }

  VpnMode loadMode() => VpnModeX.fromId(_prefs.getString(_kMode));
  Future<void> saveMode(VpnMode mode) async {
    await _prefs.setString(_kMode, mode.id);
  }
}
