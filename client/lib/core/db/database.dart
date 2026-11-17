import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class TaskLists extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get color => text().withDefault(const Constant('#4F7DF3'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get listId => text().nullable()();
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  TextColumn get dueDate => text().nullable()();
  TextColumn get dueTime => text().nullable()();
  DateTimeColumn get reminderAt => dateTime().nullable()();
  TextColumn get recurrence => text().nullable()();
  TextColumn get seriesId => text().nullable()();
  TextColumn get occurrenceDate => text().nullable()();
  TextColumn get parentId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get color => text().withDefault(const Constant('#7A8CA6'))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class TaskTags extends Table {
  TextColumn get taskId => text()();
  TextColumn get tagId => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {taskId, tagId};
}

class DailyFoci extends Table {
  TextColumn get id => text()();
  TextColumn get businessDate => text()();
  TextColumn get taskId => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Decisions extends Table {
  TextColumn get id => text()();
  TextColumn get businessDate => text()();
  IntColumn get slot => integer()();
  TextColumn get decisionText => text().withDefault(const Constant(''))();
  TextColumn get rationale => text().withDefault(const Constant(''))();
  IntColumn get aiParticipation => integer().withDefault(const Constant(0))();
  TextColumn get linkedTaskId => text().nullable()();
  TextColumn get linkedIssueId => text().nullable()();
  TextColumn get outcomeReflection => text().withDefault(const Constant(''))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Issues extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get context => text().withDefault(const Constant(''))();
  TextColumn get initialJudgment => text().withDefault(const Constant(''))();
  IntColumn get status => integer().withDefault(const Constant(0))();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class DailyReviews extends Table {
  TextColumn get id => text()();
  TextColumn get businessDate => text()();
  TextColumn get aiHelped => text().withDefault(const Constant(''))();
  TextColumn get aiOverreliance => text().withDefault(const Constant(''))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class FocusRecords extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().nullable()();
  TextColumn get label => text().withDefault(const Constant(''))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  IntColumn get durationSeconds => integer()();
  IntColumn get effectiveSeconds => integer().withDefault(const Constant(0))();
  TextColumn get sharedSessionId => text().nullable()();
  TextColumn get sourceDevice => text().withDefault(const Constant(''))();
  BoolColumn get independent => boolean().withDefault(const Constant(true))();
  BoolColumn get overlapFlag => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Synchronization metadata is separate from business rows so tombstones and
/// server versions survive even when a business row is absent locally.
class EntityMeta extends Table {
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(1))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  BoolColumn get hasConflict => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastServerAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

class SyncOperations extends Table {
  TextColumn get operationId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  IntColumn get baseVersion => integer()();
  TextColumn get payload => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get localRevision => integer()();
  IntColumn get state => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get sentAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {operationId};
}

class ConflictCopies extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get localJson => text()();
  TextColumn get serverJson => text()();
  IntColumn get serverVersion => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
  TextColumn get resolution => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class KvEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  TaskLists,
  Tasks,
  Tags,
  TaskTags,
  DailyFoci,
  Decisions,
  Issues,
  DailyReviews,
  FocusRecords,
  EntityMeta,
  SyncOperations,
  ConflictCopies,
  KvEntries,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('PRAGMA journal_mode=WAL');
          await customStatement('PRAGMA foreign_keys=ON');
          await customStatement('PRAGMA busy_timeout=5000');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys=ON');
          await customStatement('PRAGMA busy_timeout=5000');
        },
      );

  static QueryExecutor openExecutor(File file) {
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA synchronous=NORMAL');
        db.execute('PRAGMA busy_timeout=5000');
      },
    );
  }
}

Future<AppDatabase> openAppDatabase({String? overridePath}) async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final file = File(overridePath ?? p.join(dir.path, 't5_plan.sqlite'));
  return AppDatabase(AppDatabase.openExecutor(file));
}
