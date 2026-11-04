import { Clock, Effect, Predicate, Result, Schema } from "effect";
import type {
  AccountDeleted,
  InvalidMutation,
  Mutation,
  StorageFull,
} from "../../store/Changes.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { HealthToolError } from "../tools/HealthToolkit.ts";
import { localTime, toolTimeZone } from "../tools/ToolTime.ts";
import { findHealthType } from "../tools/ToolTypes.ts";
import { isJsonObject, type Json, type JsonObject } from "./CardJson.ts";
import { cardPositionBetween, cardPositionsBetween } from "./CardPosition.ts";
import { bucketRanges, type CardRange, CardSpec, maxCards } from "./CardSpec.ts";
import { type CardSpecError, canonicalCardSpec } from "./CardSpecValidator.ts";
import { requireCardsScope } from "./CardsScope.ts";
import type { CardsToolkit } from "./CardsToolkit.ts";
import { HealthCard } from "./HealthCards.ts";
import { type CardData, cardData } from "./RunCard.ts";

// The card tools on a user's store (851-3215, `docs/decisions/cards.md`, MCP tools). Reads come
// from the store's `health_card` table, and previews and data from the server's engine
// (`RunCard.ts`). Writes go through the store's `applyMutations` with whole `health_card` rows,
// the path the apps' pushes take, so each is in the change log, a live notice goes out and every
// device pulls it. The ID, `createdAt` and `updatedAt` are the server's.

type Tools = typeof CardsToolkit.tools;

/** Each card tool's implementation: its decoded parameters to its output, or its error. */
export type CardToolImplementations = {
  readonly [Name in keyof Tools]: (
    params: Tools[Name]["parametersSchema"]["Type"],
  ) => Effect.Effect<Tools[Name]["successSchema"]["Type"], HealthToolError>;
};

/** How the tools write: the store's `applyMutations`. */
export type CardWrite = (
  mutations: ReadonlyArray<Mutation>,
) => Effect.Effect<unknown, InvalidMutation | StorageFull | AccountDeleted>;

/** A card as the store keeps it, times in Unix milliseconds. */
interface StoredCard {
  readonly id: string;
  readonly spec: Json;
  readonly position: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly seed: string | null;
}

const cardColumns = "id, spec, position, created_at, updated_at, seed";

const toCard = (row: Record<string, unknown>): StoredCard => ({
  id: row["id"] as string,
  spec: JSON.parse(row["spec"] as string) as Json,
  position: row["position"] as string,
  createdAt: row["created_at"] as number,
  updatedAt: row["updated_at"] as number,
  seed: (row["seed"] as string | null) ?? null,
});

/** Every card, in Summary's order: by position, then ID, both by bytes (SQLite's BINARY). */
const readCards = (sql: StoreSql): Array<StoredCard> =>
  sql.exec(`SELECT ${cardColumns} FROM health_card ORDER BY position, id`).map(toCard);

const readCard = (sql: StoreSql, id: string): StoredCard | undefined => {
  const [row] = sql.exec(`SELECT ${cardColumns} FROM health_card WHERE id = ?`, id);
  return row === undefined ? undefined : toCard(row);
};

const fail = (message: string) => Effect.fail(new HealthToolError({ message }));

const noCard = (id: string) =>
  fail(`No card with the id ${JSON.stringify(id)}. list_cards lists them.`);

const findCard = (sql: StoreSql, id: string) =>
  Effect.suspend(() => {
    const card = readCard(sql, id);
    return card === undefined ? noCard(id) : Effect.succeed(card);
  });

/** A spec's errors as one message an agent can fix them all from: a line each, with its path. */
export const specErrorsMessage = (errors: ReadonlyArray<CardSpecError>): string =>
  [
    errors.length === 1
      ? "The spec has 1 error. Fix it and try again:"
      : `The spec has ${errors.length} errors. Fix them and try again:`,
    ...errors.map(({ path, message }) => `- ${path === "" ? "spec" : path}: ${message}`),
  ].join("\n");

/** An input spec as JSON: as given, or parsed, for agents that send it as a JSON string. */
const specJson = (input: unknown): Json | undefined => {
  if (typeof input !== "string") return input as Json;
  try {
    return JSON.parse(input) as Json;
  } catch {
    return undefined;
  }
};

/** A spec input canonicalized (`canonicalCardSpec`), or every error it has. */
const canonicalOf = (input: unknown) => {
  const json = specJson(input);
  return json === undefined
    ? {
        errors: [
          { path: "", code: "invalidJSON", message: "The spec isn't valid JSON." },
        ] satisfies ReadonlyArray<CardSpecError>,
      }
    : canonicalCardSpec(json);
};

const decodeSpec = Schema.decodeUnknownResult(CardSpec);

/** A spec input canonicalized, as JSON and as the engine's type, or the tool's error. */
const canonical = (input: unknown) =>
  Effect.suspend(() => {
    const result = canonicalOf(input);
    if (result.errors !== undefined) return fail(specErrorsMessage(result.errors));
    const decoded = decodeSpec(result.spec);
    // The validator checks more than the schema, so a spec it passes always decodes.
    if (Result.isFailure(decoded)) return Effect.die(decoded.failure);
    return Effect.succeed({ json: result.spec, spec: decoded.success });
  });

/** A stored card's spec, for the engine: this server only runs versions it reads. */
const runnable = (card: StoredCard) =>
  Effect.suspend(() => {
    const decoded = decodeSpec(card.spec);
    if (Result.isSuccess(decoded)) return Effect.succeed(decoded.success);
    const version = isJsonObject(card.spec) ? card.spec["version"] : undefined;
    return fail(
      `This card's spec is version ${JSON.stringify(version ?? null)}, which this server can't ` +
        "run. Replace it with update_card, or ask the person to update lil health.",
    );
  });

/** The range a run is over: the call's, if the card's bucket offers it, else the card's own. */
const runRange = (spec: CardSpec, range: CardRange | undefined) => {
  if (range === undefined) return Effect.succeed(spec.range);
  const ranges = bucketRanges[spec.bucket];
  return ranges.includes(range)
    ? Effect.succeed(range)
    : fail(
        `range ${JSON.stringify(range)} doesn't fit the card's bucket ` +
          `${JSON.stringify(spec.bucket)}. Use ${ranges.join(", ")}, or leave range out for the ` +
          `card's own (${spec.range}).`,
      );
};

/** A card as the tools give it, times local in `zone`. */
const cardItem = (card: StoredCard, zone: Parameters<typeof localTime>[1]) => ({
  id: card.id,
  spec: card.spec as JsonObject,
  position: card.position,
  seed: card.seed,
  createdAt: localTime(card.createdAt, zone),
  updatedAt: localTime(card.updatedAt, zone),
});

/** A card's whole row, as the store takes it. */
const upsert = (card: StoredCard): Mutation => ({
  entity: HealthCard.name,
  op: "upsert",
  id: card.id,
  row: {
    spec: card.spec,
    position: card.position,
    createdAt: card.createdAt,
    updatedAt: card.updatedAt,
    seed: card.seed,
  },
});

/** Writes through the store, with what went wrong as the tool's error. */
const writing = (write: CardWrite, mutations: ReadonlyArray<Mutation>) =>
  write(mutations).pipe(
    Effect.asVoid,
    Effect.catchTags({
      // Only a bug writes a row the store refuses: every spec is canonicalized first.
      InvalidMutation: (error) => fail(`lil health couldn't save the card: ${error.message}`),
      StorageFull: () =>
        fail("This lil account's storage is full, so lil health can't save cards right now."),
      AccountDeleted: () => fail("This lil account was deleted."),
    }),
  );

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/**
 * A new card's ID: `card_` and a ULID (`docs/decisions/cards.md`, IDs), 48 bits of the time in
 * Unix milliseconds and 80 random bits, in Crockford's base 32, as `CardID.make` makes them in
 * Swift.
 */
export const makeCardId = (now: number, random: Uint8Array): string => {
  let time = "";
  let rest = now;
  for (let index = 0; index < 10; index += 1) {
    time = crockford[rest % 32] + time;
    rest = Math.floor(rest / 32);
  }
  let randomPart = "";
  let value = 0;
  let bits = 0;
  for (const byte of random.subarray(0, 10)) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      randomPart += crockford[(value >> bits) & 31];
    }
    value &= (1 << bits) - 1;
  }
  return `card_${time}${randomPart}`;
};

const newCardId = Effect.map(Clock.currentTimeMillis, (now) =>
  makeCardId(now, crypto.getRandomValues(new Uint8Array(10))),
);

/**
 * New positions for `order`, every card once in its new order: the most cards that are already in
 * order keep theirs (the longest run of strictly ascending positions, so ties are broken), and
 * each of the others gets a key between its new neighbors'. Gives the cards whose position changes.
 */
export const reorderedPositions = (
  order: ReadonlyArray<{ readonly id: string; readonly position: string }>,
): Map<string, string> => {
  // The longest strictly ascending subsequence of positions, in O(n²): at most 200 cards.
  const lengths = order.map(() => 1);
  const previous = order.map(() => -1);
  let best = -1;
  for (let index = 0; index < order.length; index += 1) {
    for (let before = 0; before < index; before += 1) {
      if (
        order[before]!.position < order[index]!.position &&
        lengths[before]! + 1 > lengths[index]!
      ) {
        lengths[index] = lengths[before]! + 1;
        previous[index] = before;
      }
    }
    if (best === -1 || lengths[index]! > lengths[best]!) best = index;
  }
  const kept = new Set<number>();
  for (let index = best; index !== -1; index = previous[index]!) kept.add(index);

  const moved = new Map<string, string>();
  let start = 0;
  while (start < order.length) {
    if (kept.has(start)) {
      start += 1;
      continue;
    }
    let end = start;
    while (end < order.length && !kept.has(end)) end += 1;
    const lower = start === 0 ? null : order[start - 1]!.position;
    const upper = end === order.length ? null : order[end]!.position;
    const keys = cardPositionsBetween(lower, upper, end - start);
    for (let index = start; index < end; index += 1) {
      moved.set(order[index]!.id, keys[index - start]!);
    }
    start = end;
  }
  return moved;
};

/** The card tools over a user's store, writing with `write` (the store's `applyMutations`). */
export const storeCardTools = (sql: StoreSql, write: CardWrite): CardToolImplementations => ({
  list_cards: Effect.fnUntraced(function* (params) {
    const { zone, name } = yield* toolTimeZone(params.timeZone);
    return { timeZone: name, cards: readCards(sql).map((card) => cardItem(card, zone)) };
  }),

  get_card: Effect.fnUntraced(function* (params) {
    const card = yield* findCard(sql, params.id);
    const spec = yield* runnable(card);
    const range = yield* runRange(spec, params.range);
    const data = yield* cardData(sql, spec, { ...params, range });
    const { zone } = yield* toolTimeZone(params.timeZone);
    return { card: cardItem(card, zone), data };
  }),

  preview_card: Effect.fnUntraced(function* (params) {
    const { json, spec } = yield* canonical(params.spec);
    const range = yield* runRange(spec, params.range);
    const data = yield* cardData(sql, spec, { ...params, range });
    return { spec: json, data };
  }),

  create_card: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const { json } = yield* canonical(params.spec);
    const { zone, name } = yield* toolTimeZone(params.timeZone);
    const cards = readCards(sql);
    if (cards.length >= maxCards) {
      return yield* fail(
        `You have ${maxCards} cards, the most lil health keeps. Delete one first.`,
      );
    }
    const now = yield* Clock.currentTimeMillis;
    const card: StoredCard = {
      id: yield* newCardId,
      spec: json,
      position: cardPositionBetween(cards.at(-1)?.position ?? null, null),
      createdAt: now,
      updatedAt: now,
      seed: null,
    };
    yield* writing(write, [upsert(card)]);
    return { timeZone: name, card: cardItem(card, zone) };
  }),

  update_card: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const { json } = yield* canonical(params.spec);
    const { zone, name } = yield* toolTimeZone(params.timeZone);
    const stored = yield* findCard(sql, params.id);
    const now = yield* Clock.currentTimeMillis;
    // Its place, creation and seed stay. Another device's clock may have run ahead.
    const card: StoredCard = { ...stored, spec: json, updatedAt: Math.max(now, stored.createdAt) };
    yield* writing(write, [upsert(card)]);
    return { timeZone: name, card: cardItem(card, zone) };
  }),

  delete_card: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const card = yield* findCard(sql, params.id);
    yield* writing(write, [{ entity: HealthCard.name, op: "delete", id: card.id }]);
    return { deleted: card.id };
  }),

  reorder_cards: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const cards = readCards(sql);
    const byId = new Map(cards.map((card) => [card.id, card]));
    const seen = new Set<string>();
    const unknown: Array<string> = [];
    const twice: Array<string> = [];
    for (const id of params.ids) {
      if (!byId.has(id)) unknown.push(id);
      else if (seen.has(id)) twice.push(id);
      else seen.add(id);
    }
    const missing = cards.filter((card) => !seen.has(card.id)).map((card) => card.id);
    if (unknown.length > 0 || twice.length > 0 || missing.length > 0) {
      const problems = [
        missing.length > 0 ? `missing ${missing.join(", ")}` : undefined,
        unknown.length > 0 ? `unknown ${unknown.join(", ")}` : undefined,
        twice.length > 0 ? `more than once ${twice.join(", ")}` : undefined,
      ].filter(Predicate.isNotUndefined);
      return yield* fail(
        `reorder_cards needs every card's id once: ${problems.join("; ")}. list_cards lists them.`,
      );
    }
    const order = params.ids.map((id) => byId.get(id)!);
    const moved = reorderedPositions(order);
    if (moved.size > 0) {
      const now = yield* Clock.currentTimeMillis;
      yield* writing(
        write,
        order
          .filter((card) => moved.has(card.id))
          .map((card) =>
            upsert({
              ...card,
              position: moved.get(card.id)!,
              updatedAt: Math.max(now, card.createdAt),
            }),
          ),
      );
    }
    return {
      cards: order.map((card) => ({ id: card.id, position: moved.get(card.id) ?? card.position })),
    };
  }),
});

// -------------------------------------------------------------------------------------------------
// The access log
// -------------------------------------------------------------------------------------------------

/** What the access log keeps of a call (`AgentAccess`), beside its tool, outcome and rows. */
export interface AskedFor {
  readonly types: ReadonlyArray<string> | null;
  readonly range: string | null;
  readonly date: string | null;
}

/** A spec's series' types, by their catalog identifiers: the ones the catalog has. */
const typesOf = (spec: Json | undefined): ReadonlyArray<string> | null => {
  if (spec === undefined || !isJsonObject(spec)) return null;
  const series = spec["series"];
  if (!Array.isArray(series)) return null;
  const types = series.flatMap((item: Json) => {
    const type = isJsonObject(item) ? item["type"] : undefined;
    const known = typeof type === "string" ? findHealthType(type) : undefined;
    return known === undefined ? [] : [known.id];
  });
  return types.length === 0 ? null : [...new Set(types)];
};

/** An input spec's types: its canonical form's, or, with errors, those of its series named. */
const inputTypes = (input: unknown) => {
  const result = canonicalOf(input);
  return typesOf(result.spec ?? specJson(input));
};

const field = (params: object, name: string): string | null =>
  Predicate.hasProperty(params, name) && typeof params[name] === "string" ? params[name] : null;

/** How many points an answer's data has, across its series and formulas. */
const points = (encoded: unknown) => {
  const data = Predicate.hasProperty(encoded, "data") ? (encoded.data as CardData) : undefined;
  return (
    (data?.series.reduce((count, series) => count + series.points.length, 0) ?? 0) +
    (data?.formulas.reduce((count, formula) => count + formula.points.length, 0) ?? 0)
  );
};

/**
 * What the access log keeps of each card tool's calls (`docs/decisions/cards.md`, The access log):
 * the types of the spec it's given or of the card it names, read before the call runs (so a
 * deleted card's are known), `range` and `date` for runs, and `rows` the points or cards returned.
 * Never the spec or a card's name.
 */
export const cardToolLogs = (
  sql: StoreSql,
): {
  readonly [Name in keyof Tools]: {
    readonly askedFor: (params: object) => AskedFor;
    readonly rows?: (encoded: unknown) => number;
  };
} => {
  const storedTypes = (params: object) => {
    const id = field(params, "id");
    return id === null ? null : typesOf(readCard(sql, id)?.spec);
  };
  const storedRange = (params: object) => {
    const id = field(params, "id");
    const spec = id === null ? undefined : readCard(sql, id)?.spec;
    const range = spec !== undefined && isJsonObject(spec) ? spec["range"] : undefined;
    return typeof range === "string" ? range : null;
  };
  const inputRange = (params: object) => {
    const result = Predicate.hasProperty(params, "spec") ? canonicalOf(params.spec) : undefined;
    const range = result?.spec?.["range"];
    return typeof range === "string" ? range : null;
  };
  const none: AskedFor = { types: null, range: null, date: null };
  const one = () => 1;
  return {
    list_cards: { askedFor: () => none },
    get_card: {
      askedFor: (params) => ({
        types: storedTypes(params),
        range: field(params, "range") ?? storedRange(params),
        date: field(params, "date"),
      }),
      rows: points,
    },
    preview_card: {
      askedFor: (params) => ({
        types: Predicate.hasProperty(params, "spec") ? inputTypes(params.spec) : null,
        range: field(params, "range") ?? inputRange(params),
        date: field(params, "date"),
      }),
      rows: points,
    },
    create_card: {
      askedFor: (params) => ({
        ...none,
        types: Predicate.hasProperty(params, "spec") ? inputTypes(params.spec) : null,
      }),
      rows: one,
    },
    update_card: {
      askedFor: (params) => ({
        ...none,
        types: Predicate.hasProperty(params, "spec") ? inputTypes(params.spec) : null,
      }),
      rows: one,
    },
    delete_card: { askedFor: (params) => ({ ...none, types: storedTypes(params) }), rows: one },
    reorder_cards: { askedFor: () => none },
  };
};
