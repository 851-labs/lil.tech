import type { Schema } from "effect";
// Generated from the Swift `HealthCards.welcomeSeed`, its source of truth, by
// scripts/generate-health-cards, which scripts/format runs (851-3194).
import seedJson from "../../../card-seed.json" with { type: "json" };
import { applyMutations, readMeta } from "../../store/ChangeLog.ts";
import type { Mutation } from "../../store/Changes.ts";
import type { Entity } from "../../store/Entities.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { storeMaxCards } from "./CardSpec.ts";
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
  /** It's seeded now, with the cards it didn't have already (`appended` changes, maybe 0). */
  | { readonly _tag: "Seeded"; readonly appended: number }
  /**
   * It already holds so many cards that the seed's would pass the store's limit: marked seeded,
   * with none, since an account with that many cards is no newcomer.
   */
  | { readonly _tag: "Full"; readonly cards: number }
  /**
   * Seeding failed (a seed card refused, which only a bug does, or a write failed): nothing was
   * written, the flag included, so the next start tries again, once the bug is fixed.
   */
  | { readonly _tag: "Failed"; readonly error: unknown };

/**
 * Seeds the store with the welcome cards, once: if `meta` has no `health_cards_seeded` and the
 * store isn't deleted, it upserts the six through `applyMutations`, so they're in the change log
 * and every device pulls them, and sets the flag, in one transaction. Called when the store
 * starts, after its migrations, before it serves anything (`startUserStore`). It never throws, so
 * a store always starts.
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
  try {
    return sql.transaction((): SeedOutcome => {
      // A deleted store stays empty. Both are read inside the transaction, though the store seeds
      // before it serves anything, so no request can be waiting on it.
      const seeded = sql.exec("SELECT 1 FROM meta WHERE key = ?", seededKey).length > 0;
      if (seeded || readMeta(sql, "deleted", 0) === 1) return { _tag: "Skipped" };
      const stored = new Set(
        sql
          .exec(
            `SELECT id FROM "${HealthCard.name}" WHERE id IN (SELECT value FROM json_each(?))`,
            JSON.stringify(welcomeSeed.map((card) => card.id)),
          )
          .map((row) => row["id"] as string),
      );
      const mutations = seedMutations(at, stored);
      const cards = sql.exec(`SELECT count(*) AS count FROM "${HealthCard.name}"`)[0]?.[
        "count"
      ] as number;
      let outcome: SeedOutcome;
      if (cards + mutations.length > storeMaxCards) {
        outcome = { _tag: "Full", cards };
      } else {
        const { appended } = applyMutations(sql, entities, mutations, at);
        outcome = { _tag: "Seeded", appended };
      }
      sql.exec("INSERT INTO meta (key, value) VALUES (?, ?)", seededKey, at);
      return outcome;
    });
  } catch (error) {
    return { _tag: "Failed", error };
  }
};
