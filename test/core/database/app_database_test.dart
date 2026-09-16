import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('Drift 데이터베이스를 메모리에서 생성할 수 있다', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final result = await database
        .customSelect('PRAGMA user_version')
        .getSingle();

    expect(result.read<int>('user_version'), database.schemaVersion);
  });

  test('v1 DB를 최신 스키마로 마이그레이션하며 기존 데이터를 보존한다', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'review_platform_migration_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final databaseFile = File('${tempDirectory.path}/migration.sqlite');

    final legacyDatabase = sqlite.sqlite3.open(databaseFile.path);
    legacyDatabase.execute('CREATE TABLE legacy_data (value TEXT NOT NULL)');
    legacyDatabase.execute("INSERT INTO legacy_data VALUES ('preserved')");
    legacyDatabase.execute('PRAGMA user_version = 1');
    legacyDatabase.close();

    final database = AppDatabase(NativeDatabase(databaseFile));
    addTearDown(database.close);

    final folderTable = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'folders'",
        )
        .getSingle();
    final legacyRow = await database
        .customSelect('SELECT value FROM legacy_data')
        .getSingle();

    expect(folderTable.read<String>('name'), 'folders');
    expect(legacyRow.read<String>('value'), 'preserved');
  });

  test('v2 Folder 데이터를 보존하며 Question 테이블을 추가한다', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'review_platform_question_migration_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final databaseFile = File('${tempDirectory.path}/migration.sqlite');

    final legacyDatabase = sqlite.sqlite3.open(databaseFile.path);
    legacyDatabase.execute('''
      CREATE TABLE folders (
        id TEXT NOT NULL PRIMARY KEY,
        parent_id TEXT NULL REFERENCES folders(id),
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER NULL
      )
    ''');
    legacyDatabase.execute(
      "INSERT INTO folders VALUES ('folder-1', NULL, '전자기학', 0, 0, NULL)",
    );
    legacyDatabase.execute('PRAGMA user_version = 2');
    legacyDatabase.close();

    final database = AppDatabase(NativeDatabase(databaseFile));
    addTearDown(database.close);

    final folder = await database
        .customSelect("SELECT name FROM folders WHERE id = 'folder-1'")
        .getSingle();
    final questionTable = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'questions'",
        )
        .getSingle();

    expect(folder.read<String>('name'), '전자기학');
    expect(questionTable.read<String>('name'), 'questions');
  });

  test('v3 Question 데이터를 보존하며 Quiz와 Attempt 테이블을 추가한다', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'review_platform_quiz_migration_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final databaseFile = File('${tempDirectory.path}/migration.sqlite');

    final legacyDatabase = sqlite.sqlite3.open(databaseFile.path);
    legacyDatabase.execute('''
      CREATE TABLE folders (
        id TEXT NOT NULL PRIMARY KEY,
        parent_id TEXT NULL REFERENCES folders(id),
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER NULL
      )
    ''');
    legacyDatabase.execute('''
      CREATE TABLE questions (
        id TEXT NOT NULL PRIMARY KEY,
        folder_id TEXT NOT NULL REFERENCES folders(id),
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        prompt TEXT NOT NULL,
        explanation TEXT NULL,
        difficulty INTEGER NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER NULL
      )
    ''');
    legacyDatabase.execute('''
      CREATE TABLE question_choices (
        id TEXT NOT NULL PRIMARY KEY,
        question_id TEXT NOT NULL REFERENCES questions(id),
        position INTEGER NOT NULL,
        text TEXT NOT NULL,
        is_correct INTEGER NOT NULL
      )
    ''');
    legacyDatabase.execute('''
      CREATE TABLE acceptable_answers (
        id TEXT NOT NULL PRIMARY KEY,
        question_id TEXT NOT NULL REFERENCES questions(id),
        text TEXT NOT NULL
      )
    ''');
    legacyDatabase.execute(
      "INSERT INTO folders VALUES ('folder-1', NULL, '물리', 0, 0, NULL)",
    );
    legacyDatabase.execute('''
      INSERT INTO questions VALUES (
        'question-1', 'folder-1', 'shortAnswer', 'approved',
        '빛의 속도는?', NULL, NULL, 0, 0, NULL
      )
    ''');
    legacyDatabase.execute('PRAGMA user_version = 3');
    legacyDatabase.close();

    final database = AppDatabase(NativeDatabase(databaseFile));
    addTearDown(database.close);

    final question = await database
        .customSelect("SELECT prompt FROM questions WHERE id = 'question-1'")
        .getSingle();
    final newTables = await database.customSelect('''
          SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name IN ('quiz_sessions', 'attempts', 'quiz_session_items')
        ''').get();

    expect(question.read<String>('prompt'), '빛의 속도는?');
    expect(newTables.map((row) => row.read<String>('name')), hasLength(3));
  });
}
