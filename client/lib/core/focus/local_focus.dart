import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class LocalFocusState {
  const LocalFocusState({
    this.running = false,
    this.paused = false,
    this.taskId,
    this.label = '',
    this.targetSeconds = 1500,
    this.elapsedSeconds = 0,
    this.sessionStartedAt,
    this.finished = false,
  });

  final bool running;
  final bool paused;
  final String? taskId;
  final String label;
  final int targetSeconds;
  final int elapsedSeconds;
  final DateTime? sessionStartedAt;
  final bool finished;

  int get remainingSeconds => (targetSeconds - elapsedSeconds).clamp(0, targetSeconds);
  double get progress => targetSeconds == 0 ? 0 : (elapsedSeconds / targetSeconds).clamp(0, 1);
  bool get active => running || paused;

  LocalFocusState copyWith({
    bool? running,
    bool? paused,
    String? taskId,
    bool clearTask = false,
    String? label,
    int? targetSeconds,
    int? elapsedSeconds,
    DateTime? sessionStartedAt,
    bool? finished,
  }) =>
      LocalFocusState(
        running: running ?? this.running,
        paused: paused ?? this.paused,
        taskId: clearTask ? null : (taskId ?? this.taskId),
        label: label ?? this.label,
        targetSeconds: targetSeconds ?? this.targetSeconds,
        elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
        sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
        finished: finished ?? this.finished,
      );
}

class LocalFocusNotifier extends Notifier<LocalFocusState> {
  Stopwatch? _stopwatch;
  int _accumulatedSeconds = 0;
  Timer? _ticker;

  @override
  LocalFocusState build() {
    ref.onDispose(() {
      _ticker?.cancel();
      _stopwatch?.stop();
    });
    return const LocalFocusState();
  }

  void start({
    String? taskId,
    String label = '',
    int? targetMinutes,
  }) {
    final prefs = ref.read(appPreferencesProvider);
    _ticker?.cancel();
    _stopwatch = Stopwatch()..start();
    _accumulatedSeconds = 0;
    state = LocalFocusState(
      running: true,
      taskId: taskId,
      label: label,
      targetSeconds: (targetMinutes ?? prefs.focusMinutes) * 60,
      sessionStartedAt: DateTime.now().toUtc(),
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void pause() {
    if (!state.running) return;
    _accumulatedSeconds += _stopwatch?.elapsed.inSeconds ?? 0;
    _stopwatch?.stop();
    _ticker?.cancel();
    state = state.copyWith(running: false, paused: true, elapsedSeconds: _accumulatedSeconds);
  }

  void resume() {
    if (!state.paused) return;
    _stopwatch = Stopwatch()..start();
    state = state.copyWith(running: true, paused: false);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  Future<void> end({bool completed = false}) async {
    if (!state.active) return;
    _ticker?.cancel();
    final elapsed = _accumulatedSeconds + (_stopwatch?.elapsed.inSeconds ?? 0);
    _stopwatch?.stop();
    final start = state.sessionStartedAt ?? DateTime.now().toUtc();
    final end = DateTime.now().toUtc();
    if (elapsed >= 1) {
      await ref.read(taskRepositoryProvider).addFocusRecord(
            taskId: state.taskId,
            label: state.label,
            startedAt: start,
            endedAt: end,
            focusedDurationSeconds: elapsed,
          );
    }
    state = LocalFocusState(
      targetSeconds: state.targetSeconds,
      elapsedSeconds: elapsed,
      finished: completed,
      label: state.label,
      taskId: state.taskId,
    );
  }

  void dismissFinished() {
    state = const LocalFocusState();
  }

  void _tick() {
    final elapsed = _accumulatedSeconds + (_stopwatch?.elapsed.inSeconds ?? 0);
    if (elapsed >= state.targetSeconds) {
      unawaited(end(completed: true));
      return;
    }
    state = state.copyWith(elapsedSeconds: elapsed);
  }
}

final localFocusProvider = NotifierProvider<LocalFocusNotifier, LocalFocusState>(
  LocalFocusNotifier.new,
  name: 'localFocus',
);

