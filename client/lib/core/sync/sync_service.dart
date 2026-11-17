import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../db/database.dart';
import '../db/repository.dart';
import '../settings/preferences.dart';
import 'entity_codec.dart';

class SyncSnapshot {
  const SyncSnapshot({
    this.phase = SyncPhase.idle,
    this.pending = 0,
    this.syncing = 0,
    this.conflicts = 0,
    this.lastError,
    this.lastSyncedAt,
  });

  final SyncPhase phase;
  final int pending;
  final int syncing;
  final int conflicts;
  final String? lastError;
  final DateTime? lastSyncedAt;

  bool get isBusy => phase == SyncPhase.pushing || phase == SyncPhase.pulling || phase == SyncPhase.bootstrap;
  SyncSnapshot copyWith({
    SyncPhase? phase,
    int? pending,
    int? syncing,
    int? conflicts,
    String? lastError,
    DateTime? lastSyncedAt,
    bool clearError = false,
  }) =>
      SyncSnapshot(
        phase: phase ?? this.phase,
        pending: pending ?? this.pending,
        syncing: syncing ?? this.syncing,
        conflicts: conflicts ?? this.conflicts,
        lastError: clearError ? null : (lastError ?? this.lastError),
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
}

enum SyncPhase { idle, waiting, pushing, pulling, bootstrap, paused, offline, error }

class SyncService {
  SyncService({
    required this.db,
    required this.api,
    required this.prefs,
    required this.repository,
    required this.deviceId,
    this.tokenReader,
    this.pausedReader,
  });

  final AppDatabase db;
  final ApiClient api;
  final AppPreferences prefs;
  final TaskRepository repository;
  final String deviceId;
  final Future<String?> Function()? tokenReader;
  final bool Function()? pausedReader;
  static const _uuid = Uuid();

  final _controller = StreamController<SyncSnapshot>.broadcast();
  SyncSnapshot _snapshot = const SyncSnapshot();
  Future<SyncSnapshot>? _inFlight;
  Timer? _debounce;
  Timer? _periodic;
  Timer? _retry;
  int _failures = 0;
  bool _disposed = false;

  Stream<SyncSnapshot> get snapshots => _controller.stream;
  SyncSnapshot get snapshot => _snapshot;

  Future<void> initialize() async {
    await _repairMissingOps();
    await refreshStatus();
    _periodic ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isPaused && !_snapshot.isBusy) unawaited(syncNow(silent: true));
    });
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _retry?.cancel();
    _controller.close();
  }

  void requestSyncSoon() {
    if (_disposed || _isPaused) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(syncNow(silent: true)));
  }

  void setBackgroundMode(bool background) {
    _periodic?.cancel();
    _periodic = Timer.periodic(
      background ? const Duration(minutes: 5) : const Duration(seconds: 30),
      (_) {
        if (!_isPaused && !_snapshot.isBusy) unawaited(syncNow(silent: true));
      },
    );
  }

  void setPaused(bool paused) {
    if (paused) {
      _periodic?.cancel();
      _periodic = null;
      _emit(_snapshot.copyWith(phase: SyncPhase.paused));
    } else {
      _failures = 0;
      _periodic ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (!_snapshot.isBusy) unawaited(syncNow(silent: true));
      });
      scheduleMicrotask(() => unawaited(syncNow(silent: true)));
    }
  }

  bool get _isPaused => pausedReader?.call() ?? prefs.syncPaused;

  Future<SyncSnapshot> syncNow({bool silent = false, bool bootstrapOnly = false}) {
    if (_isPaused) return Future.value(_snapshot.copyWith(phase: SyncPhase.paused));
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _run(silent: silent, bootstrapOnly: bootstrapOnly).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<SyncSnapshot> _run({required bool silent, required bool bootstrapOnly}) async {
    _retry?.cancel();
    try {
      final token = tokenReader == null ? await prefs.readToken() : await tokenReader!();
      if (token?.isEmpty ?? true) {
        _emit(_snapshot.copyWith(phase: SyncPhase.offline, lastError: '尚未配对服务器'));
        return _snapshot;
      }
      String? generation = await _kv('sync_generation');
      if (generation == null || generation.isEmpty) {
        await _bootstrap();
        generation = await _kv('sync_generation');
      }
      if (bootstrapOnly) {
        await refreshStatus();
        _emit(_snapshot.copyWith(phase: SyncPhase.idle, clearError: true, lastSyncedAt: DateTime.now()));
        return _snapshot;
      }
      await _repairMissingOps();
      await _pushPending();
      if (generation != null && generation.isNotEmpty) {
        await _pullChanges(generation);
      }
      _failures = 0;
      _emit(_snapshot.copyWith(
        phase: SyncPhase.idle,
        clearError: true,
        lastSyncedAt: DateTime.now(),
      ));
      await refreshStatus();
      return _snapshot;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        _emit(_snapshot.copyWith(phase: SyncPhase.error, lastError: '设备令牌已失效，请重新配对'));
      } else if (e.code == 'generation_mismatch') {
        try {
          await _bootstrap();
          _emit(_snapshot.copyWith(phase: SyncPhase.idle, clearError: true));
        } catch (inner) {
          _scheduleRetry(inner.toString());
        }
      } else {
        _scheduleRetry(e.message);
      }
      return _snapshot;
    } catch (e) {
      _scheduleRetry(e.toString());
      return _snapshot;
    } finally {
      await refreshStatus();
    }
  }

  void _scheduleRetry(String message) {
    _failures = min(_failures + 1, 8);
    final base = min(300, pow(2, _failures).toInt());
    final jitter = Random.secure().nextInt(max(1, base * 250));
    final delay = Duration(seconds: base) + Duration(milliseconds: jitter);
    _emit(_snapshot.copyWith(phase: SyncPhase.error, lastError: message));
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(syncNow(silent: true)));
  }

  Future<void> _bootstrap() async {
    _emit(_snapshot.copyWith(phase: SyncPhase.bootstrap, clearError: true));
    String? afterType;
    String? afterId;
    String? generation;
    var snapshotSeq = 0;
    while (true) {
      final page = await api.bootstrap(afterType: afterType, afterId: afterId, limit: 500);
      generation = page['generation'] as String?;
      snapshotSeq = (page['snapshot_seq'] as num?)?.toInt() ?? 0;
      final entities = (page['entities'] as List? ?? const []).cast<Map<String, dynamic>>();
      await _applyServerPage(entities, advanceCursor: false);
      if (page['has_more'] != true) break;
      afterType = page['next_after_type'] as String?;
      afterId = page['next_after_id'] as String?;
      if (afterType == null || afterId == null) break;
    }
    if (generation != null) {
      await db.transaction(() async {
        await _setKv('sync_generation', generation!);
        await _setKv('sync_cursor', snapshotSeq.toString());
      });
    }
  }

  Future<void> _pullChanges(String generation) async {
    var cursor = int.tryParse(await _kv('sync_cursor') ?? '0') ?? 0;
    while (true) {
      _emit(_snapshot.copyWith(phase: SyncPhase.pulling, clearError: true));
      final page = await api.changes(generation: generation, cursor: cursor, limit: 500);
      final serverGen = page['generation'] as String?;
      if (serverGen != null && serverGen != generation) {
        throw ApiException(409, 'generation_mismatch', '同步世代已变化');
      }
      final changes = (page['changes'] as List? ?? const []).cast<Map<String, dynamic>>();
      final nextCursor = (page['next_cursor'] as num?)?.toInt() ?? cursor;
      await _applyServerPage(changes, advanceCursor: true, cursor: nextCursor);
      cursor = nextCursor;
      if (page['has_more'] != true) break;
    }
  }

  Future<void> _pushPending() async {
    while (true) {
      final ops = await (db.select(db.syncOperations)
            ..where((t) => t.state.equals(0))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
            ..limit(50))
          .get();
      if (ops.isEmpty) return;
      _emit(_snapshot.copyWith(phase: SyncPhase.pushing, syncing: ops.length, clearError: true));
      await (db.update(db.syncOperations)..where((t) => t.operationId.isIn(ops.map((e) => e.operationId))))
          .write(SyncOperationsCompanion(
        state: const Value(1),
        sentAt: Value(DateTime.now().toUtc()),
      ));
      final payload = [
        for (final op in ops)
          {
            'operation_id': op.operationId,
            'entity_type': op.entityType,
            'entity_id': op.entityId,
            'base_version': op.baseVersion,
            'deleted': op.deleted,
            if (!op.deleted) 'payload': decodeJsonObject(op.payload),
          }
      ];
      Map<String, dynamic> response;
      try {
        response = await api.push(payload);
      } catch (e) {
        await (db.update(db.syncOperations)
              ..where((t) => t.operationId.isIn(ops.map((e) => e.operationId))))
            .write(const SyncOperationsCompanion(state: Value(0)));
        rethrow;
      }
      final results = (response['results'] as List? ?? const []).cast<Map<String, dynamic>>();
      for (final result in results) {
        await _applyPushResult(ops.firstWhere((o) => o.operationId == result['operation_id']), result);
      }
      final returned = results.map((r) => r['operation_id']).toSet();
      for (final op in ops.where((o) => !returned.contains(o.operationId))) {
        // Missing results must be retried with the same immutable operation id.
        await (db.update(db.syncOperations)..where((t) => t.operationId.equals(op.operationId)))
            .write(const SyncOperationsCompanion(state: Value(0)));
      }
    }
  }

  Future<void> _applyPushResult(SyncOperation op, Map<String, dynamic> result) async {
    final accepted = result['accepted'] == true;
    final conflict = result['conflict'] == true;
    final serverVersion = (result['server_version'] as num?)?.toInt() ?? op.baseVersion;
    if (accepted) {
      await db.transaction(() async {
        final meta = await _meta(op.entityType, op.entityId);
        if (meta != null) {
          final localUnchanged = meta.localRevision == op.localRevision;
          await (db.update(db.entityMeta)
                ..where((t) => t.entityType.equals(op.entityType) & t.entityId.equals(op.entityId)))
              .write(EntityMetaCompanion(
            serverVersion: Value(serverVersion),
            dirty: Value(localUnchanged ? false : meta.dirty),
            lastServerAt: Value(DateTime.now().toUtc()),
          ));
        }
        await (db.delete(db.syncOperations)..where((t) => t.operationId.equals(op.operationId))).go();
      });
      await _ensureCurrentOperation(op.entityType, op.entityId, serverVersion);
    } else if (conflict) {
      final entity = result['entity'] as Map<String, dynamic>?;
      await _recordConflict(op, entity, serverVersion);
    } else {
      await (db.update(db.syncOperations)..where((t) => t.operationId.equals(op.operationId)))
          .write(const SyncOperationsCompanion(state: Value(0)));
    }
  }

  Future<void> _recordConflict(
    SyncOperation op,
    Map<String, dynamic>? serverEntity,
    int serverVersion,
  ) async {
    final serverJson = jsonEncode({
      'version': serverVersion,
      'deleted': serverEntity?['deleted'] == true,
      'data': serverEntity?['data'],
    });
    await db.transaction(() async {
      await db.into(db.conflictCopies).insert(ConflictCopiesCompanion.insert(
        id: _uuid.v4(),
        entityType: op.entityType,
        entityId: op.entityId,
        localJson: op.payload,
        serverJson: serverJson,
        serverVersion: serverVersion,
        createdAt: DateTime.now().toUtc(),
      ));
      await (db.update(db.entityMeta)
            ..where((t) => t.entityType.equals(op.entityType) & t.entityId.equals(op.entityId)))
          .write(EntityMetaCompanion(
        serverVersion: Value(serverVersion),
        hasConflict: const Value(true),
        dirty: const Value(false),
        lastServerAt: Value(DateTime.now().toUtc()),
      ));
      await (db.delete(db.syncOperations)..where((t) => t.operationId.equals(op.operationId))).go();
    });
  }

  Future<void> _applyServerPage(
    List<Map<String, dynamic>> entities, {
    required bool advanceCursor,
    int? cursor,
  }) async {
    await db.transaction(() async {
      for (final raw in entities) {
        final type = raw['entity_type'] as String?;
        final id = raw['entity_id'] as String?;
        final version = (raw['version'] as num?)?.toInt() ?? 0;
        final deleted = raw['deleted'] == true;
        if (type == null || id == null) continue;
        final meta = await _meta(type, id);
        if (meta != null && version <= meta.serverVersion) continue;
        final pending = await (db.select(db.syncOperations)
              ..where((t) => t.entityType.equals(type) & t.entityId.equals(id))
              ..limit(1))
            .getSingleOrNull();
        final localChanged = (meta?.dirty ?? false) || (meta?.hasConflict ?? false) || pending != null;
        if (localChanged && meta != null && version > meta.serverVersion) {
          final data = raw['data'];
          await db.into(db.conflictCopies).insert(ConflictCopiesCompanion.insert(
            id: _uuid.v4(),
            entityType: type,
            entityId: id,
            localJson: pending?.payload ?? jsonEncode({'deleted': meta.deleted}),
            serverJson: jsonEncode({'version': version, 'deleted': deleted, 'data': data}),
            serverVersion: version,
            createdAt: DateTime.now().toUtc(),
          ));
          await (db.update(db.entityMeta)
                ..where((t) => t.entityType.equals(type) & t.entityId.equals(id)))
              .write(EntityMetaCompanion(
            serverVersion: Value(version),
            hasConflict: const Value(true),
            dirty: const Value(false),
            lastServerAt: Value(DateTime.now().toUtc()),
          ));
          if (pending != null) {
            await (db.delete(db.syncOperations)..where((t) => t.operationId.equals(pending.operationId))).go();
          }
          continue;
        }
        await applyServerEntity(
          db,
          type,
          id,
          decodeJsonObject(raw['data']),
          deleted: deleted,
          serverUpdatedAt: DateTime.tryParse(raw['server_updated_at']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
        );
        await db.into(db.entityMeta).insertOnConflictUpdate(EntityMetaCompanion(
          entityType: Value(type),
          entityId: Value(id),
          serverVersion: Value(version),
          localRevision: Value(meta?.localRevision ?? 1),
          dirty: const Value(false),
          hasConflict: const Value(false),
          deleted: Value(deleted),
          lastServerAt: Value(DateTime.tryParse(raw['server_updated_at']?.toString() ?? '')?.toUtc()),
        ));
      }
      if (advanceCursor && cursor != null) {
        await _setKv('sync_cursor', cursor.toString());
      }
    });
  }

  Future<void> _repairMissingOps() async {
    final dirty = await (db.select(db.entityMeta)
          ..where((t) => t.dirty.equals(true) & t.hasConflict.equals(false)))
        .get();
    for (final meta in dirty) {
      final pending = await (db.select(db.syncOperations)
            ..where((t) =>
                t.entityType.equals(meta.entityType) & t.entityId.equals(meta.entityId))
            ..limit(1))
          .getSingleOrNull();
      if (pending == null) {
        await _ensureCurrentOperation(meta.entityType, meta.entityId, meta.serverVersion);
      }
    }
  }

  Future<void> _ensureCurrentOperation(String type, String entityId, int baseVersion) async {
    final meta = await _meta(type, entityId);
    if (meta == null || !meta.dirty || meta.hasConflict) return;
    final existing = await (db.select(db.syncOperations)
          ..where((t) => t.entityType.equals(type) & t.entityId.equals(entityId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return;
    final payload = await _currentPayload(type, entityId);
    if (payload == null) return;
    await db.into(db.syncOperations).insert(SyncOperationsCompanion.insert(
      operationId: _uuid.v4(),
      entityType: type,
      entityId: entityId,
      baseVersion: baseVersion,
      payload: jsonEncode(payload),
      deleted: Value(meta.deleted),
      localRevision: meta.localRevision,
      state: const Value(0),
      createdAt: DateTime.now().toUtc(),
    ));
  }

  Future<Map<String, dynamic>?> _currentPayload(String type, String entityId) async {
    switch (type) {
      case 'task':
        final row = await (db.select(db.tasks)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : taskToJson(row);
      case 'task_list':
        final row = await (db.select(db.taskLists)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : taskListToJson(row);
      case 'tag':
        final row = await (db.select(db.tags)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : tagToJson(row);
      case 'daily_focus':
        final row = await (db.select(db.dailyFoci)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : dailyFocusToJson(row);
      case 'decision':
        final row = await (db.select(db.decisions)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : decisionToJson(row);
      case 'issue':
        final row = await (db.select(db.issues)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : issueToJson(row);
      case 'daily_review':
        final row = await (db.select(db.dailyReviews)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : dailyReviewToJson(row);
      case 'focus_record':
        final row = await (db.select(db.focusRecords)..where((t) => t.id.equals(entityId))).getSingleOrNull();
        return row == null ? null : focusRecordToJson(row);
    }
    return null;
  }

  Future<EntityMetaData?> _meta(String type, String id) => (db.select(db.entityMeta)
        ..where((t) => t.entityType.equals(type) & t.entityId.equals(id)))
      .getSingleOrNull();

  Future<String?> _kv(String key) async {
    final row = await (db.select(db.kvEntries)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _setKv(String key, String value) =>
      db.into(db.kvEntries).insertOnConflictUpdate(KvEntriesCompanion.insert(key: key, value: value));

  Future<void> refreshStatus() async {
    final pending = await (db.selectOnly(db.syncOperations)
          ..addColumns([db.syncOperations.operationId.count()])
          ..where(db.syncOperations.state.equals(0)))
        .map((r) => r.read(db.syncOperations.operationId.count()) ?? 0)
        .getSingle();
    final syncing = await (db.selectOnly(db.syncOperations)
          ..addColumns([db.syncOperations.operationId.count()])
          ..where(db.syncOperations.state.equals(1)))
        .map((r) => r.read(db.syncOperations.operationId.count()) ?? 0)
        .getSingle();
    final conflicts = await (db.selectOnly(db.conflictCopies)
          ..addColumns([db.conflictCopies.id.count()])
          ..where(db.conflictCopies.resolvedAt.isNull()))
        .map((r) => r.read(db.conflictCopies.id.count()) ?? 0)
        .getSingle();
    _emit(_snapshot.copyWith(pending: pending, syncing: syncing, conflicts: conflicts));
  }

  Stream<List<ConflictCopy>> watchConflicts() => (db.select(db.conflictCopies)
        ..where((t) => t.resolvedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
      .watch();

  Future<void> resolveKeepLocal(ConflictCopy conflict) async {
    await db.transaction(() async {
      final meta = await _meta(conflict.entityType, conflict.entityId);
      await (db.update(db.entityMeta)
            ..where((t) =>
                t.entityType.equals(conflict.entityType) & t.entityId.equals(conflict.entityId)))
          .write(EntityMetaCompanion(
        hasConflict: const Value(false),
        dirty: const Value(true),
        serverVersion: Value(conflict.serverVersion),
        localRevision: Value((meta?.localRevision ?? 1) + 1),
      ));
      await (db.update(db.conflictCopies)..where((t) => t.id.equals(conflict.id))).write(
        ConflictCopiesCompanion(
          resolvedAt: Value(DateTime.now().toUtc()),
          resolution: const Value('local'),
        ),
      );
    });
    await _ensureCurrentOperation(conflict.entityType, conflict.entityId, conflict.serverVersion);
    await syncNow(silent: true);
  }

  Future<void> resolveKeepCloud(ConflictCopy conflict) async {
    final server = decodeJsonObject(conflict.serverJson);
    final deleted = server['deleted'] == true;
    await db.transaction(() async {
      await applyServerEntity(
        db,
        conflict.entityType,
        conflict.entityId,
        decodeJsonObject(server['data']),
        deleted: deleted,
        serverUpdatedAt: DateTime.now().toUtc(),
      );
      final meta = await _meta(conflict.entityType, conflict.entityId);
      await db.into(db.entityMeta).insertOnConflictUpdate(EntityMetaCompanion(
        entityType: Value(conflict.entityType),
        entityId: Value(conflict.entityId),
        serverVersion: Value(conflict.serverVersion),
        localRevision: Value((meta?.localRevision ?? 1) + 1),
        dirty: const Value(false),
        hasConflict: const Value(false),
        deleted: Value(deleted),
        lastServerAt: Value(DateTime.now().toUtc()),
      ));
      await (db.delete(db.syncOperations)
            ..where((t) =>
                t.entityType.equals(conflict.entityType) & t.entityId.equals(conflict.entityId)))
          .go();
      await (db.update(db.conflictCopies)..where((t) => t.id.equals(conflict.id))).write(
        ConflictCopiesCompanion(
          resolvedAt: Value(DateTime.now().toUtc()),
          resolution: const Value('cloud'),
        ),
      );
    });
    await refreshStatus();
  }

  Future<void> resolveManual(ConflictCopy conflict, Map<String, dynamic> merged) async {
    final server = decodeJsonObject(conflict.serverJson);
    final deleted = server['deleted'] == true;
    await db.transaction(() async {
      if (!deleted) {
        await applyServerEntity(
          db,
          conflict.entityType,
          conflict.entityId,
          merged,
          deleted: false,
          serverUpdatedAt: DateTime.now().toUtc(),
        );
      }
      final meta = await _meta(conflict.entityType, conflict.entityId);
      await db.into(db.entityMeta).insertOnConflictUpdate(EntityMetaCompanion(
        entityType: Value(conflict.entityType),
        entityId: Value(conflict.entityId),
        serverVersion: Value(conflict.serverVersion),
        localRevision: Value((meta?.localRevision ?? 1) + 1),
        dirty: const Value(true),
        hasConflict: const Value(false),
        deleted: Value(deleted),
        lastServerAt: Value(DateTime.now().toUtc()),
      ));
      await (db.update(db.conflictCopies)..where((t) => t.id.equals(conflict.id))).write(
        ConflictCopiesCompanion(
          resolvedAt: Value(DateTime.now().toUtc()),
          resolution: const Value('manual'),
        ),
      );
    });
    await _ensureCurrentOperation(conflict.entityType, conflict.entityId, conflict.serverVersion);
    await syncNow(silent: true);
  }

  void _emit(SyncSnapshot s) {
    _snapshot = s;
    if (!_disposed) _controller.add(s);
  }
}
