import * as D1Drizzle from "drizzle-orm/effect-d1";
import type { EffectDrizzleQueryError, QueryEffectHKTBase } from "drizzle-orm/effect-core";
import type { SQLiteEffectDatabase } from "drizzle-orm/sqlite-core/effect";
import { Context, Effect, Layer, Predicate } from "effect";
import { SqlError } from "effect/sql";

/**
 * What a query against the core database fails with and needs: Drizzle's query error, and
 * nothing. The D1 driver (the Worker) and the Node SQLite one (tests) both have this shape, so the
 * repositories work on either.
 */
interface CoreQueryEffect extends QueryEffectHKTBase {
  readonly error: EffectDrizzleQueryError;
  readonly context: never;
}

/** The core D1 database through Drizzle (`Schema.ts`). Repositories query it. */
export class CoreDb extends Context.Service<
  CoreDb,
  SQLiteEffectDatabase<CoreQueryEffect, unknown>
>()("lil/api/core/CoreDb") {
  /** Over D1 (`@effect/sql-d1`'s `D1Client`, which Alchemy's `SQL.D1Layer` provides). */
  static readonly d1 = Layer.effect(CoreDb, D1Drizzle.makeWithDefaults({}));
}

/**
 * Drizzle's query error as the `SqlError` the repositories have always failed with, so callers
 * that handle `SqlError` keep working. The driver's own `SqlError` is usually its cause.
 */
export const asSqlError = (error: EffectDrizzleQueryError): SqlError.SqlError =>
  Predicate.isTagged(error.cause, "SqlError")
    ? (error.cause as SqlError.SqlError)
    : new SqlError.SqlError({ reason: new SqlError.UnknownError({ cause: error }) });

/** Runs a Drizzle query, failing with `SqlError` (`asSqlError`). */
export const query = <A>(
  effect: Effect.Effect<A, EffectDrizzleQueryError>,
): Effect.Effect<A, SqlError.SqlError> => Effect.mapError(effect, asSqlError);
