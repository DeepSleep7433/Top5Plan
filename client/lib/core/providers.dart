import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'db/database.dart';
import 'models/domain.dart';
import 'db/repository.dart';
import 'export/export_service.dart';
import 'notifications/reminder_service.dart';
import 'settings/preferences.dart';
import 'sync/sync_service.dart';
import 'time/account_clock.dart';

final appPreferencesProvider = Provider<AppPreferences>((ref) => throw UnimplementedError());
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());
final apiClientProvider = Provider<ApiClient>((ref) => throw UnimplementedError());
final taskRepositoryProvider = Provider<TaskRepository>((ref) => throw UnimplementedError());
final syncServiceProvider = Provider<SyncService>((ref) => throw UnimplementedError());
final reminderServiceProvider = Provider<ReminderService>((ref) => throw UnimplementedError());
final exportServiceProvider = Provider<ExportService>((ref) => throw UnimplementedError());
final deviceIdProvider = Provider<String>((ref) => throw UnimplementedError());

class TimezoneNotifier extends Notifier<String> {
  @override
  String build() => ref.read(appPreferencesProvider).timezone;

  Future<void> setTimezone(String value) async {
    ref.read(appPreferencesProvider).timezone = value;
    state = value;
    ref.read(reminderServiceProvider).timezone = value;
  }
}

final timezoneProvider =
    NotifierProvider<TimezoneNotifier, String>(TimezoneNotifier.new, name: 'timezone');

final clockProvider = Provider<AccountClock>((ref) => AccountClock(ref.watch(timezoneProvider)));

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final v = ref.read(appPreferencesProvider).themeMode;
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    ref.read(appPreferencesProvider).themeMode = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    state = mode;
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new, name: 'themeMode');

Stream<SyncSnapshot> _syncStream(SyncService sync) async* {
  yield sync.snapshot;
  yield* sync.snapshots;
}

final syncSnapshotProvider = StreamProvider<SyncSnapshot>((ref) {
  final sync = ref.watch(syncServiceProvider);
  return _syncStream(sync);
});

final conflictsProvider = StreamProvider((ref) {
  return ref.watch(syncServiceProvider).watchConflicts();
});

final todayProvider = Provider<String>((ref) {
  final clock = ref.watch(clockProvider);
  return clock.today();
});

final focusTasksProvider = StreamProvider.autoDispose.family<List<Task>, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).watchFocusTasks(date);
});

final todayDueProvider = StreamProvider.autoDispose.family<List<Task>, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).watchTodayDueTasks(date);
});

final decisionsProvider = StreamProvider.autoDispose.family<List<Decision>, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).watchDecisions(date);
});

final dailyReviewProvider = StreamProvider.autoDispose.family<DailyReview?, String>((ref, date) {
  return ref.watch(taskRepositoryProvider).watchDailyReview(date);
});

final issuesProvider = StreamProvider.autoDispose.family<List<Issue>, int?>((ref, status) {
  return ref.watch(taskRepositoryProvider).watchIssues(
        status: status == null ? null : IssueStatus.fromValue(status),
      );
});

final listsProvider = StreamProvider.autoDispose((ref) {
  return ref.watch(taskRepositoryProvider).watchLists();
});

final tagsProvider = StreamProvider.autoDispose((ref) {
  return ref.watch(taskRepositoryProvider).watchTags();
});

final todayFocusSecondsProvider = StreamProvider.autoDispose((ref) {
  return ref.watch(taskRepositoryProvider).watchTodayFocusSeconds();
});

final todayCompletedProvider = StreamProvider.autoDispose((ref) {
  return ref.watch(taskRepositoryProvider).watchTodayCompletedCount();
});

