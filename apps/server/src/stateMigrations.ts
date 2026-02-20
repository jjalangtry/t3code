import * as Effect from "effect/Effect";
import * as Migrator from "effect/unstable/sql/Migrator";
import * as SqlClient from "effect/unstable/sql/SqlClient";
import { PersistenceInitializationError } from "./persistence/errors";
import { MIGRATION_V1_SQL } from "./persistence/migrations";
import type { EffectSqliteDatabaseAdapter, SqliteDatabase } from "./sqliteAdapter";

export const STATE_DB_SCHEMA_VERSION = 1;

export function applyStateDbPragmas(db: SqliteDatabase): void {
  db.exec("PRAGMA journal_mode=WAL;");
  db.exec("PRAGMA synchronous=FULL;");
  db.exec("PRAGMA busy_timeout=5000;");
  db.exec("PRAGMA foreign_keys=ON;");
}

function normalizeStatementBatch(sql: string): string[] {
  const normalized = sql.replace(/\r\n/g, "\n");
  const statements: string[] = [];
  let current = "";
  let inSingleQuote = false;
  let inDoubleQuote = false;
  let inBacktick = false;

  for (const char of normalized) {
    if (char === "'" && !inDoubleQuote && !inBacktick) {
      inSingleQuote = !inSingleQuote;
      current += char;
      continue;
    }
    if (char === '"' && !inSingleQuote && !inBacktick) {
      inDoubleQuote = !inDoubleQuote;
      current += char;
      continue;
    }
    if (char === "`" && !inSingleQuote && !inDoubleQuote) {
      inBacktick = !inBacktick;
      current += char;
      continue;
    }
    if (char === ";" && !inSingleQuote && !inDoubleQuote && !inBacktick) {
      const statement = current.trim();
      if (statement.length > 0) {
        statements.push(statement);
      }
      current = "";
      continue;
    }
    current += char;
  }

  const trailing = current.trim();
  if (trailing.length > 0) {
    statements.push(trailing);
  }
  return statements;
}

function isEffectSqliteDatabase(db: SqliteDatabase): db is EffectSqliteDatabaseAdapter {
  return "runWithSqlClient" in db && typeof db.runWithSqlClient === "function";
}

function runEffectMigrations(db: EffectSqliteDatabaseAdapter): void {
  const migrationV1Effect = Effect.gen(function*() {
    const sql = yield* SqlClient.SqlClient;
    for (const statement of normalizeStatementBatch(MIGRATION_V1_SQL)) {
      yield* sql.unsafe(statement).raw;
    }
    yield* sql.unsafe(`PRAGMA user_version=${STATE_DB_SCHEMA_VERSION};`).raw;
  });

  const migrationLoader = Migrator.fromRecord({
    "0001_initial_schema": migrationV1Effect,
  });
  const runMigrations = Migrator.make({});

  db.runWithSqlClient(
    runMigrations({ loader: migrationLoader }).pipe(
      Effect.mapError((error) => {
        const message =
          error instanceof Error
            ? error.message
            : `Failed to run Effect SQL migrations for state database.`;
        return new Error(message, { cause: error });
      }),
    ),
  );
}

export function runStateMigrations(db: SqliteDatabase): void {
  applyStateDbPragmas(db);

  if (!isEffectSqliteDatabase(db)) {
    throw new PersistenceInitializationError("Expected Effect-backed sqlite adapter for migrations");
  }
  runEffectMigrations(db);
}
