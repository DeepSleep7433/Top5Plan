import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AppPreferences {
  AppPreferences(this._prefs, this._secure);
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kBaseUrl = 'base_url';
  static const _kDeviceName = 'device_name';
  static const _kTheme = 'theme_mode';
  static const _kAutoStart = 'auto_start';
  static const _kHotkey = 'quick_capture_hotkey';
  static const _kSyncPaused = 'sync_paused';
  static const _kAutoUpdateCheck = 'auto_update_check';
  static const _kTimezone = 'account_timezone';
  static const _kFocusMinutes = 'focus_minutes';
  static const _kShortBreak = 'short_break_minutes';
  static const _kLongBreakMinutes = 'long_break_minutes';
  static const _kLongBreakEvery = 'long_break_every';
  static const _kDeviceId = 'device_id';
  static const _kToken = 'device_token';

  static Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppPreferences(prefs, const FlutterSecureStorage());
  }

  String get baseUrl => _prefs.getString(_kBaseUrl) ?? 'http://127.0.0.1:8080';
  set baseUrl(String v) => _prefs.setString(_kBaseUrl, v.trim());

  String get deviceName {
    final existing = _prefs.getString(_kDeviceName);
    if (existing != null && existing.isNotEmpty) return existing;
    final host = Platform.localHostname;
    return host.isEmpty ? 'T5 device' : host;
  }

  set deviceName(String v) => _prefs.setString(_kDeviceName, v.trim());

  String get themeMode => _prefs.getString(_kTheme) ?? 'system';
  set themeMode(String v) => _prefs.setString(_kTheme, v);

  bool get autoStart => _prefs.getBool(_kAutoStart) ?? false;
  set autoStart(bool v) => _prefs.setBool(_kAutoStart, v);

  String get hotkey => _prefs.getString(_kHotkey) ?? 'ctrl+alt+t';
  set hotkey(String v) => _prefs.setString(_kHotkey, v);

  bool get syncPaused => _prefs.getBool(_kSyncPaused) ?? false;
  set syncPaused(bool v) => _prefs.setBool(_kSyncPaused, v);

  bool get autoUpdateCheck => _prefs.getBool(_kAutoUpdateCheck) ?? true;
  set autoUpdateCheck(bool v) => _prefs.setBool(_kAutoUpdateCheck, v);

  String get timezone => _prefs.getString(_kTimezone) ?? 'Asia/Shanghai';
  set timezone(String v) => _prefs.setString(_kTimezone, v);

  int get focusMinutes => _prefs.getInt(_kFocusMinutes) ?? 25;
  set focusMinutes(int v) => _prefs.setInt(_kFocusMinutes, v);

  int get shortBreakMinutes => _prefs.getInt(_kShortBreak) ?? 5;
  set shortBreakMinutes(int v) => _prefs.setInt(_kShortBreak, v);

  int get longBreakMinutes => _prefs.getInt(_kLongBreakMinutes) ?? 15;
  set longBreakMinutes(int v) => _prefs.setInt(_kLongBreakMinutes, v);

  int get longBreakEvery => _prefs.getInt(_kLongBreakEvery) ?? 4;
  set longBreakEvery(int v) => _prefs.setInt(_kLongBreakEvery, v);

  Future<String> ensureDeviceId() async {
    final existing = await _prefs.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await _prefs.setString(_kDeviceId, id);
    return id;
  }

  Future<String?> readToken() => _secure.read(key: _kToken);
  Future<void> writeToken(String token) => _secure.write(key: _kToken, value: token);
  Future<void> clearToken() => _secure.delete(key: _kToken);


}

