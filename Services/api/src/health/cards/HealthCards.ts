import type { Schema } from "effect";
import { Column, defineEntity } from "../../store/Entities.ts";
import { cardPositionError } from "./CardPosition.ts";
import { storeMaxCards } from "./CardSpec.ts";
import { storedCardSpecErrors } from "./CardSpecValidator.ts";

// Summary's cards (851-3202, `docs/decisions/cards.md`, The `health_card` sync entity): the second
// entity apps write, after `health_pin`, and the first agents write through the server.

/** A card's ID: `card_` and a ULID made by whoever creates it, or a seed card's fixed one. */
const cardId = /^card_(?:[0-9A-HJKMNP-TV-Z]{26}|seed_([a-z_]{1,40}))$/;

/** One thing wrong with a card's row: where in the row, and why. */
export interface CardRowError {
  readonly path: string;
  readonly message: string;
}

/**
 * What's wrong with a card's whole row, each with its path in the row (`spec.series[0].type`), or
 * nothing: its spec valid, canonical and at most 16 KB, its position a fractional index of 1 to
 * 200 characters, `createdAt` no later than `updatedAt`, and `seed` set on seed cards only, to
 * the seed card's name (`card_seed_steps` is `steps`).
 */
export const cardRowErrors = (
  id: string,
  row: Readonly<Record<string, Schema.Json>>,
): ReadonlyArray<CardRowError> => {
  const errors: Array<CardRowError> = storedCardSpecErrors(row["spec"] ?? null).map((error) => ({
    message: error.message,
    path: error.path === "" ? "spec" : `spec.${error.path}`,
  }));
  const position = cardPositionError(typeof row["position"] === "string" ? row["position"] : "");
  if (position !== undefined) errors.push({ path: position.path, message: position.message });
  const createdAt = Number(row["createdAt"]);
  const updatedAt = Number(row["updatedAt"]);
  if (createdAt > updatedAt) {
    errors.push({
      path: "updatedAt",
      message: `updatedAt (${updatedAt}) can't be before createdAt (${createdAt}).`,
    });
  }
  const seed = cardId.exec(id)?.[1] ?? null;
  if ((row["seed"] ?? null) !== seed) {
    errors.push({
      path: "seed",
      message:
        seed === null
          ? "seed must be null: only seed cards (card_seed_…) have one."
          : `seed must be ${JSON.stringify(seed)}, the seed card's name.`,
    });
  }
  return errors;
};

/** A card's errors as one message, a line each, for `MutationRejected`. */
const checkCardRow = (id: string, row: Readonly<Record<string, Schema.Json>>) => {
  const errors = cardRowErrors(id, row);
  if (errors.length === 0) return undefined;
  const count = errors.length === 1 ? "1 error" : `${errors.length} errors`;
  return [
    `The card ${id} has ${count}:`,
    ...errors.map(({ path, message }) => `- ${path}: ${message}`),
  ].join("\n");
};

/**
 * One of Summary's cards: a chart defined by its spec. Apps write whole rows (every field), so the
 * last writer wins per card and a card is never a mix of two edits.
 */
export const HealthCard = defineEntity("health_card", {
  clientWritable: true,
  wholeRows: true,
  maxRecords: storeMaxCards,
  id: cardId,
  fields: {
    /** The spec, in canonical form (`docs/decisions/cards.md`, The card spec, v1). */
    spec: Column.json,
    /** Summary's order: a fractional index, ascending, ties by ID (`CardPosition.ts`). */
    position: Column.text,
    /** When it was made, in Unix milliseconds. Never changes. */
    createdAt: Column.integer,
    /** When it was last written, in Unix milliseconds, reorders included. Decides nothing. */
    updatedAt: Column.integer,
    /** The seed card it started as (`steps`), else null. */
    seed: Column.nullable(Column.text),
  },
  checkRow: checkCardRow,
});
