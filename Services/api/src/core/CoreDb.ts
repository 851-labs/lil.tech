import * as D1Drizzle from "drizzle-orm/effect-d1";
import type { EffectDrizzleQueryError, QueryEffectHKTBase } from "drizzle-orm/effect-core";
import type { SQLiteEffectDatabase } from "drizzle-orm/sqlite-core/effect";
import { Cause, Context, Effect, Layer, Option, Predicate } from "effect";
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
 * that handle `SqlError` keep working. Drizzle wraps the driver's error in a `Cause`; that error is
 * usually the driver's own `SqlError`, with its reason (a constraint, a lost connection).
 */
export const asSqlError = (error: EffectDrizzleQueryError): SqlError.SqlError => {
  const inner = Cause.isCause(error.cause)
    ? Option.getOrUndefined(Cause.findErrorOption(error.cause))
    : error.cause;
  return Predicate.isTagged(inner, "SqlError")
    ? (inner as SqlError.SqlError)
    : new SqlError.SqlError({ reason: new SqlError.UnknownError({ cause: error }) });
};

/** Runs a Drizzle query, failing with `SqlError` (`asSqlError`). */
export const query = <A>(
  effect: Effect.Effect<A, EffectDrizzleQueryError>,
): Effect.Effect<A, SqlError.SqlError> => Effect.mapError(effect, asSqlError);

/** The first row, decoded, if there is one. A row that doesn't decode is a defect. */
export const first =
  <A>(decode: (row: unknown) => Effect.Effect<A, unknown>) =>
  (rows: ReadonlyArray<unknown>): Effect.Effect<Option.Option<A>> =>
    rows[0] === undefined
      ? Effect.succeed(Option.none())
      : decode(rows[0]).pipe(Effect.orDie, Effect.map(Option.some));
