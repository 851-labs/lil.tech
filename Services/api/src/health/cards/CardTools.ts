import { Clock, Effect, Predicate, Result, Schema } from "effect";
import type {
  AccountDeleted,
  InvalidMutation,
  Mutation,
  StorageFull,
} from "../../store/Changes.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { HealthToolError } from "../tools/HealthToolkit.ts";
import { isLocalDay, localTime, toolTimeZone } from "../tools/ToolTime.ts";
import { findHealthType } from "../tools/ToolTypes.ts";
import { isJsonObject, type Json, type JsonObject } from "./CardJson.ts";
import { cardPositionBetween, cardPositionsBetween } from "./CardPosition.ts";
import {
  bucketRanges,
  type CardRange,
  CardSpec,
  maxCards,
  readableCardSpecVersions,
} from "./CardSpec.ts";
import { type CardSpecError, type CardSpecResult, canonicalCardSpec } from "./CardSpecValidator.ts";
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

/**
 * Each object spec's canonical form, once per call: the access log (`cardToolLogs`) and the tool
 * both need it, and it's the same object for both.
 */
const canonicalized = new WeakMap<object, CardSpecResult>();

/** A spec input canonicalized (`canonicalCardSpec`), or every error it has. */
const canonicalOf = (input: unknown): CardSpecResult => {
  if (Predicate.isObject(input)) {
    const cached = canonicalized.get(input);
    if (cached !== undefined) return cached;
  }
  const json = specJson(input);
  const result: CardSpecResult =
    json === undefined
      ? { errors: [{ path: "", code: "invalidJSON", message: "The spec isn't valid JSON." }] }
      : canonicalCardSpec(json);
  if (Predicate.isObject(input)) canonicalized.set(input, result);
  return result;
};

/** A spec input canonicalized, as JSON, or the tool's error listing every one it has. */
const canonical = (input: unknown) =>
  Effect.suspend(() => {
    const result = canonicalOf(input);
    return result.errors === undefined
      ? Effect.succeed(result.spec)
      : fail(specErrorsMessage(result.errors));
  });

const decodeSpec = Schema.decodeUnknownResult(CardSpec);

/**
 * A canonical spec as the engine's type. This server runs the versions it reads; one it can't
 * decode otherwise (which the validator and the schema agreeing rules out) is the tool's error.
 */
const runnable = (spec: Json) =>
  Effect.suspend(() => {
    const decoded = decodeSpec(spec);
    if (Result.isSuccess(decoded)) return Effect.succeed(decoded.success);
    const version = isJsonObject(spec) ? spec["version"] : undefined;
    return fail(
      typeof version === "number" && readableCardSpecVersions.includes(version)
        ? "lil health's server can't run this card's spec. Replace it with update_card."
        : `This card's spec is version ${JSON.stringify(version ?? null)}, which this server ` +
            "can't run. Replace it with update_card, or ask the person to update lil health.",
    );
  });

/** The latest of a card's times and now: a card's `updatedAt` never goes back. */
const updatedAt = (card: StoredCard, now: number) => Math.max(now, card.updatedAt, card.createdAt);

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

/**
 * A stored spec with its keys in the design's order, as the writes return it: the store keeps its
 * JSON with sorted keys. The values are the same, since the store only keeps canonical specs; one
 * this server can't read (a later version) comes as it's stored.
 */
const inDesignOrder = (spec: Json): JsonObject =>
  canonicalCardSpec(spec).spec ?? (spec as JsonObject);

/** A card as the tools give it, times local in `zone`. */
const cardItem = (card: StoredCard, zone: Parameters<typeof localTime>[1]) => ({
  id: card.id,
  spec: inDesignOrder(card.spec),
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
    const spec = yield* runnable(card.spec);
    const range = yield* runRange(spec, params.range);
    const data = yield* cardData(sql, spec, { ...params, range });
    const { zone } = yield* toolTimeZone(params.timeZone);
    return { card: cardItem(card, zone), data };
  }),

  preview_card: Effect.fnUntraced(function* (params) {
    const json = yield* canonical(params.spec);
    const spec = yield* runnable(json);
    const range = yield* runRange(spec, params.range);
    const data = yield* cardData(sql, spec, { ...params, range });
    return { spec: json, data };
  }),

  create_card: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const json = yield* canonical(params.spec);
    const { zone, name } = yield* toolTimeZone(params.timeZone);
    // How many there are, and the last one's position, without reading every spec.
    const [count] = sql.exec("SELECT count(*) AS count FROM health_card");
    const [last] = sql.exec(
      "SELECT position FROM health_card ORDER BY position DESC, id DESC LIMIT 1",
    );
    if (Number(count?.["count"] ?? 0) >= maxCards) {
      return yield* fail(
        `You have ${maxCards} cards, the most lil health keeps. Delete one first.`,
      );
    }
    const now = yield* Clock.currentTimeMillis;
    const card: StoredCard = {
      id: yield* newCardId,
      spec: json,
      position: cardPositionBetween((last?.["position"] as string | undefined) ?? null, null),
      createdAt: now,
      updatedAt: now,
      seed: null,
    };
    yield* writing(write, [upsert(card)]);
    return { timeZone: name, card: cardItem(card, zone) };
  }),

  update_card: Effect.fnUntraced(function* (params) {
    yield* requireCardsScope;
    const json = yield* canonical(params.spec);
    const { zone, name } = yield* toolTimeZone(params.timeZone);
    const stored = yield* findCard(sql, params.id);
    const now = yield* Clock.currentTimeMillis;
    // Its place, creation and seed stay. Another device's clock may have run ahead.
    const card: StoredCard = { ...stored, spec: json, updatedAt: updatedAt(stored, now) };
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
    // Each id once in the message, however often it's given.
    const unknown = new Set<string>();
    const twice = new Set<string>();
    for (const id of params.ids) {
      if (!byId.has(id)) unknown.add(id);
      else if (seen.has(id)) twice.add(id);
      else seen.add(id);
    }
    const missing = cards.filter((card) => !seen.has(card.id)).map((card) => card.id);
    if (unknown.size > 0 || twice.size > 0 || missing.length > 0) {
      const problems = [
        missing.length > 0 ? `missing ${missing.join(", ")}` : undefined,
        unknown.size > 0 ? `unknown ${[...unknown].join(", ")}` : undefined,
        twice.size > 0 ? `more than once ${[...twice].join(", ")}` : undefined,
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
              updatedAt: updatedAt(card, now),
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

/** The card a call named, created or changed, as the access log keeps it (851-4011). */
export interface LoggedCard {
  readonly cardId: string | null;
  readonly cardName: string | null;
}

/** What the access log keeps of a call (`AgentAccess`), beside its tool, outcome and rows. */
export interface AskedFor extends LoggedCard {
  readonly types: ReadonlyArray<string> | null;
  readonly range: string | null;
  readonly date: string | null;
}

/** A call that asked for nothing the log keeps. */
export const askedForNothing: AskedFor = {
  types: null,
  range: null,
  date: null,
  cardId: null,
  cardName: null,
};

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

/** A spec's name (`display.name`), if it has one. */
const nameOf = (spec: Json | undefined): string | null => {
  const display = spec !== undefined && isJsonObject(spec) ? spec["display"] : undefined;
  const name = display !== undefined && isJsonObject(display) ? display["name"] : undefined;
  return typeof name === "string" ? name : null;
};

/** The card an answer holds (`HealthCardResult`'s `card`), encoded. */
const answeredCard = (encoded: unknown): LoggedCard | undefined => {
  if (!Predicate.hasProperty(encoded, "card") || !Predicate.isObject(encoded.card))
    return undefined;
  const card = encoded.card;
  const id = Predicate.hasProperty(card, "id") && typeof card.id === "string" ? card.id : null;
  const spec = Predicate.hasProperty(card, "spec") ? (card.spec as Json) : undefined;
  return { cardId: id, cardName: nameOf(spec) };
};

/**
 * What the log reads an input spec's types and name from: its canonical form, or, with errors,
 * the spec as given (its series named, and its name as the Mac's server logs it,
 * `HealthTools.cardName`, so a refused create still says which card it was).
 */
const inputSpec = (params: object): Json | undefined => {
  if (!Predicate.hasProperty(params, "spec")) return undefined;
  return canonicalOf(params.spec).spec ?? specJson(params.spec);
};

const field = (params: object, name: string): string | null =>
  Predicate.hasProperty(params, name) && typeof params[name] === "string" ? params[name] : null;

/**
 * A run's `date`, if it's a day: the input schema takes any string (851-3217), so the run can
 * refuse one that isn't, and the log keeps no text an agent made up in its place.
 */
const dayField = (params: object): string | null => {
  const date = field(params, "date");
  return date !== null && isLocalDay(date) ? date : null;
};

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
 * deleted card's are known), `range` and `date` for runs, `rows` the points or cards returned,
 * and the card it created, changed or deleted, with its name (851-4011): the stored card's, the
 * input spec's, or for a write that went through, the card it wrote. Never the spec.
 */
export const cardToolLogs = (
  sql: StoreSql,
): {
  readonly [Name in keyof Tools]: {
    readonly askedFor: (params: object) => AskedFor;
    readonly rows?: (encoded: unknown) => number;
    /** The card an answer holds, which a write made: the ID a create gave it. */
    readonly card?: (encoded: unknown) => LoggedCard | undefined;
  };
} => {
  const stored = (params: object) => {
    const id = field(params, "id");
    return id === null ? undefined : readCard(sql, id);
  };
  /** The ID a call names, if it's a card's: never one an agent made up. */
  const storedId = (params: object) => {
    const id = field(params, "id");
    return id !== null && sql.exec("SELECT 1 FROM health_card WHERE id = ?", id).length > 0
      ? id
      : null;
  };
  const rangeOf = (spec: Json | undefined) => {
    const range = spec !== undefined && isJsonObject(spec) ? spec["range"] : undefined;
    return typeof range === "string" ? range : null;
  };
  const inputRange = (params: object) =>
    rangeOf(Predicate.hasProperty(params, "spec") ? canonicalOf(params.spec).spec : undefined);
  const one = () => 1;
  /** A write's types and name, from the spec it's given. */
  const written = (params: object) => {
    const spec = inputSpec(params);
    return { ...askedForNothing, types: typesOf(spec), cardName: nameOf(spec) };
  };
  return {
    list_cards: { askedFor: () => askedForNothing },
    // A read names no card: the log keeps the cards agents changed (the privacy policy's "which
    // card it created, changed or deleted"), and a read's types say what it read.
    get_card: {
      askedFor: (params) => {
        const spec = stored(params)?.spec;
        return {
          ...askedForNothing,
          types: typesOf(spec),
          range: field(params, "range") ?? rangeOf(spec),
          date: dayField(params),
        };
      },
      rows: points,
    },
    preview_card: {
      askedFor: (params) => ({
        ...askedForNothing,
        types: typesOf(inputSpec(params)),
        range: field(params, "range") ?? inputRange(params),
        date: dayField(params),
      }),
      rows: points,
    },
    create_card: { askedFor: written, rows: one, card: answeredCard },
    update_card: {
      askedFor: (params) => ({ ...written(params), cardId: storedId(params) }),
      rows: one,
      card: answeredCard,
    },
    delete_card: {
      askedFor: (params) => {
        const card = stored(params);
        return {
          ...askedForNothing,
          types: typesOf(card?.spec),
          cardId: card?.id ?? null,
          cardName: nameOf(card?.spec),
        };
      },
      rows: one,
    },
    reorder_cards: { askedFor: () => askedForNothing },
  };
};
