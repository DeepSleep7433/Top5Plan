import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../app_info.dart';
import '../providers.dart';

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.downloadUrl,
    required this.sha256,
    required this.releaseNotes,
    required this.mandatory,
    required this.publishedAt,
  });

  final String version;
  final String downloadUrl;
  final String sha256;
  final String releaseNotes;
  final bool mandatory;
  final DateTime? publishedAt;

  factory UpdateRelease.fromJson(Map<String, dynamic> json) => UpdateRelease(
        version: json['version']?.toString() ?? '',
        downloadUrl: json['download_url']?.toString() ?? '',
        sha256: json['sha256']?.toString() ?? '',
        releaseNotes: json['release_notes']?.toString() ?? '',
        mandatory: json['mandatory'] == true,
        publishedAt: DateTime.tryParse(json['published_at']?.toString() ?? '')?.toUtc(),
      );
}

class UpdateState {
  const UpdateState({
    this.checking = false,
    this.checked = false,
    this.updateAvailable = false,
    this.latest,
    this.error,
    this.lastCheckedAt,
  });

  final bool checking;
  final bool checked;
  final bool updateAvailable;
  final UpdateRelease? latest;
  final String? error;
  final DateTime? lastCheckedAt;

  String get currentVersion => appVersion;

  UpdateState copyWith({
    bool? checking,
    bool? checked,
    bool? updateAvailable,
    UpdateRelease? latest,
    String? error,
    bool clearError = false,
    DateTime? lastCheckedAt,
  }) =>
      UpdateState(
        checking: checking ?? this.checking,
        checked: checked ?? this.checked,
        updateAvailable: updateAvailable ?? this.updateAvailable,
        latest: latest ?? this.latest,
        error: clearError ? null : (error ?? this.error),
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      );
}

class UpdateNotifier extends Notifier<UpdateState> {
  bool _inFlight = false;

  @override
  UpdateState build() => const UpdateState();

  Future<UpdateState> check({bool force = false}) async {
    if (_inFlight) return state;
    _inFlight = true;
    state = state.copyWith(checking: true, clearError: true);
    try {
      final prefs = ref.read(appPreferencesProvider);
      if (!force && !prefs.autoUpdateCheck) {
        state = state.copyWith(checking: false, checked: true);
        return state;
      }
      final api = ref.read(apiClientProvider);
      final platform = Platform.isWindows ? 'windows' : 'android';
      final out = await api.latestAppUpdate(
        platform: platform,
        currentVersion: appVersion,
      );
      final raw = out['latest'];
      final latest = raw is Map<String, dynamic> ? UpdateRelease.fromJson(raw) : null;
      state = UpdateState(
        checking: false,
        checked: true,
        updateAvailable: out['update_available'] == true,
        latest: latest,
        lastCheckedAt: DateTime.now().toUtc(),
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        checking: false,
        checked: true,
        error: e.message,
        lastCheckedAt: DateTime.now().toUtc(),
      );
    } catch (e) {
      state = state.copyWith(
        checking: false,
        checked: true,
        error: e.toString(),
        lastCheckedAt: DateTime.now().toUtc(),
      );
    } finally {
      _inFlight = false;
    }
    return state;
  }
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
  name: 'appUpdate',
);
