import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../db/database.dart';
import '../models/domain.dart';

class ReminderService {
  ReminderService(this.db, this.timezone);
  final AppDatabase db;
  String timezone;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool permissionGranted = true;

  Future<void> initialize() async {
    if (_initialized) return;
    final android = const AndroidInitializationSettings('@drawable/ic_notification');
    final windows = const WindowsInitializationSettings(
      appName: 'T5 决策与待办',
      appUserModelId: 'com.t5plan.T5Plan',
      guid: '8b7f2862-3c46-4b89-b282-457cf774a5b2',
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, windows: windows),
    );
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      permissionGranted = granted ?? true;
    }
    _initialized = true;
  }

  Future<void> rescheduleAll() async {
    await initialize();
    await _plugin.cancelAll();
    final active = await (db.select(db.tasks)
          ..where((t) =>
              t.deleted.equals(false) &
              t.archived.equals(false) &
              t.status.isNotValue(TaskStatus.done.value) &
              t.reminderAt.isNotNull()))
        .get();
    final location = tz.getLocation(timezone);
    for (final task in active) {
      final when = task.reminderAt;
      if (when == null || when.isBefore(DateTime.now().toUtc())) continue;
      final scheduled = tz.TZDateTime.from(when, location);
      final id = task.id.hashCode & 0x7fffffff;
      await _plugin.zonedSchedule(
        id: id,
        title: task.title,
        body: task.dueTime == null ? '待办提醒' : '截止 ${task.dueDate ?? ''} ${task.dueTime}',
        scheduledDate: scheduled,
        notificationDetails: NotificationDetails(
          android: const AndroidNotificationDetails(
            't5_reminders',
            '任务提醒',
            channelDescription: 'T5 任务与截止时间提醒',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
          ),
          windows: const WindowsNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'task:${task.id}',
      );
    }
  }

  Future<void> showNow(String title, String body, {String? payload}) async {
    await initialize();
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: const AndroidNotificationDetails(
          't5_reminders',
          '任务提醒',
          channelDescription: 'T5 任务与截止时间提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        windows: const WindowsNotificationDetails(),
      ),
      payload: payload,
    );
  }
}
