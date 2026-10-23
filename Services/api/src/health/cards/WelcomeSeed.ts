import type { Schema } from "effect";
// Generated from the Swift `HealthCards.welcomeSeed`, its source of truth, by
// scripts/generate-health-cards, which scripts/format runs (851-3194).
import seedJson from "../../../card-seed.json" with { type: "json" };
import { applyMutations, readMeta } from "../../store/ChangeLog.ts";
import { InvalidMutation, type Mutation } from "../../store/Changes.ts";
import type { Entity } from "../../store/Entities.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { HealthCard } from "./HealthCards.ts";

// The welcome seed (851-3203, `docs/decisions/cards.md`, The welcome seed): every account starts
// with Summary's six metrics as cards. The server seeds each store once, never the apps, so two
// devices never seed twice, and a deleted seed card never comes back.

/** A seed card's row, but for its times. */
export interface SeedCard {
  readonly id: string;
  readonly seed: string;
  readonly position: string;
  readonly spec: Schema.Json;
}

/** Summary's six metrics, in Summary's order, as `HealthCards.welcomeSeed` defines them. */
export const welcomeSeed: ReadonlyArray<SeedCard> = seedJson.cards as ReadonlyArray<SeedCard>;

/** The `meta` key set, to when, once a store was seeded. Never cleared, so seeding is once. */
export const seededKey = "health_cards_seeded";

/** The seed's upserts, whole rows written at `at`, for the cards `stored` doesn't have. */
const seedMutations = (at: number, stored: ReadonlySet<string>): ReadonlyArray<Mutation> =>
  welcomeSeed
    .filter((card) => !stored.has(card.id))
    .map((card) => ({
      entity: HealthCard.name,
      op: "upsert",
      id: card.id,
      row: {
        spec: card.spec,
        position: card.position,
        createdAt: at,
        updatedAt: at,
        seed: card.seed,
      },
    }));

/** What seeding a store did. */
export type SeedOutcome =
  /** It was seeded before, or is deleted, or keeps no cards: nothing changed. */
  | { readonly _tag: "Skipped" }
  /** It's seeded now, with the cards it didn't have already (`appended` changes). */
  | { readonly _tag: "Seeded"; readonly appended: number }
  /** The store refused the seed (say, it already holds 200 cards): marked seeded, with none. */
  | { readonly _tag: "Refused"; readonly message: string };

/**
 * Seeds the store with the welcome cards, once: if `meta` has no `health_cards_seeded` and the
 * store isn't deleted, it upserts the six through `applyMutations`, so they're in the change log
 * and every device pulls them, and sets the flag, in one transaction. Called when the store
 * starts, after its migrations, before it serves anything (`startUserStore`).
 *
 * A seed card the store already has (a store that lost its flag, say) is left as it is, never
 * overwritten: the fixed IDs mean seeding again could only ever write the same six. A store whose
 * registry has no `health_card` (some tests') isn't seeded.
 */
export const seedWelcomeCards = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  at: number,
): SeedOutcome => {
  const entities = new Map(registry.map((entity) => [entity.name, entity]));
  if (!entities.has(HealthCard.name)) return { _tag: "Skipped" };
  return sql.transaction((): SeedOutcome => {
    // A deleted store stays empty. Both are read inside the transaction, though the store seeds
    // before it serves anything, so no request can be waiting on it.
    const seeded = sql.exec("SELECT 1 FROM meta WHERE key = ?", seededKey).length > 0;
    if (seeded || readMeta(sql, "deleted", 0) === 1) {
      return { _tag: "Skipped" };
    }
    const stored = new Set(
      sql
        .exec(
          `SELECT id FROM "${HealthCard.name}" WHERE id IN (SELECT value FROM json_each(?))`,
          JSON.stringify(welcomeSeed.map((card) => card.id)),
        )
        .map((row) => row["id"] as string),
    );
    let outcome: SeedOutcome;
    try {
      // A nested transaction: refused, it writes nothing, and the flag is still set below.
      const { appended } = applyMutations(sql, entities, seedMutations(at, stored), at);
      outcome = { _tag: "Seeded", appended };
    } catch (error) {
      if (!(error instanceof InvalidMutation)) throw error;
      outcome = { _tag: "Refused", message: error.message };
    }
    sql.exec("INSERT INTO meta (key, value) VALUES (?, ?)", seededKey, at);
    return outcome;
  });
};
