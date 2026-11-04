import { Effect, Schema } from "effect";
import { Tool, Toolkit } from "effect/ai";
import {
  HealthToolError,
  LocalDate,
  LocalTime,
  timeZone,
  usedTimeZone,
} from "../tools/HealthToolkit.ts";
import { cardWeekdays } from "./CardCalendar.ts";
import {
  cardAggregations,
  cardBuckets,
  cardChartStyles,
  cardColors,
  cardRanges,
  CardSpecInput,
  maxCards,
  storeMaxCards,
} from "./CardSpec.ts";

// The card tools (851-3215, `docs/decisions/cards.md`, MCP tools): how agents read, preview,
// create, change, delete and reorder the cards on lil health's Summary. Like the Health toolkit
// (`HealthToolkit.ts`), they're defined once, here, and listed in `mcp-tools.json` after its ten,
// so `lil-health mcp` on the Mac registers them from the file too (851-3216). The remote server
// implements them from the user's store (`CardTools.ts`).
//
// Reading and previewing need `health:read`, which every grant has; the four writes need
// `health:cards` too, and only ever write cards, never Health data. Outputs are part of the API's
// contract, as the Health tools' are: they can gain fields, but never lose or rename one.

// -------------------------------------------------------------------------------------------------
// Inputs
// -------------------------------------------------------------------------------------------------

/**
 * The five example cards (`docs/decisions/cards.md`, The five example cards) as an agent may write
 * them, defaults left out: the descriptions show them, and a test checks each canonicalizes to the
 * design's form.
 */
export const cardSpecExamples = {
  "body temperature as a line": {
    version: 1,
    display: { name: "Body Temperature", symbol: "thermometer.medium", color: "red" },
    series: [{ type: "BodyTemperature" }],
    range: "M",
    chart: { style: "line" },
  },
  "heart rate while asleep, per night": {
    version: 1,
    display: { name: "Sleeping Heart Rate", symbol: "moon.zzz.fill", color: "indigo" },
    series: [{ type: "HeartRate", window: { kind: "asleep" } }],
    bucket: "night",
    range: "M",
    chart: { style: "line" },
  },
  "HRV as dots, with a 7-point moving average": {
    version: 1,
    display: { name: "HRV", symbol: "waveform.path.ecg", color: "pink" },
    series: [{ type: "HeartRateVariabilitySDNN" }],
    formulas: [{ id: "trend", kind: "movingAverage", of: "a", points: 7 }],
    range: "M",
    chart: { style: "dots" },
  },
  "heart rate in the 5 minutes before falling asleep, per night": {
    version: 1,
    display: { name: "Heart Rate Before Sleep", symbol: "bed.double.fill", color: "mint" },
    series: [{ type: "Heart Rate", window: { kind: "beforeSleep", minutes: 5 } }],
    bucket: "night",
    range: "M",
    chart: { style: "dots" },
  },
  "the first weigh-in each day before noon, with a 7-day rolling average": {
    version: 1,
    display: { name: "Morning Weight", symbol: "scalemass.fill", color: "purple" },
    series: [
      {
        type: "BodyMass",
        aggregation: "first",
        window: { kind: "timeOfDay", from: "00:00", to: "12:00" },
        label: "First weigh-in before noon",
      },
    ],
    formulas: [
      { id: "trend", kind: "movingAverage", of: "a", points: 7, label: "7-day rolling average" },
    ],
    bucket: "day",
    range: "M",
    chart: { style: "dots" },
  },
} as const;

/** The spec in brief, for the descriptions: enough to write a valid one with the input schema. */
const specGuide = [
  "A card spec is JSON. Only version (1, or 2 for a workout window's location), display.name " +
    "and each series' type are required: leave the rest out for their defaults. Outputs give the " +
    "canonical form, every default filled in, at the lowest version that has what it uses.",
  "- display: name (1-40 characters), symbol (one of the schema's SF Symbols; default the " +
    `type's), color (${cardColors.join(", ")}; default the type's), unit (e.g. kg, lb, degF, ` +
    "km; null for the person's locale).",
  "- series: 1 to 4, sharing one axis, so one unit. Each is a quantity type (an identifier, or " +
    'a name such as "Heart Rate": list_types and search find them) and an aggregation per ' +
    `bucket (${cardAggregations.join(", ")}): types that add up (steps, energy, distance) take ` +
    "sum only, others avg (the default), min, max, first, latest or count. Optional: id (a, b, " +
    "c, d by default), label, hidden.",
  "- window, for types that don't add up, keeps readings that start in it: " +
    '{"kind": "asleep"}, {"kind": "beforeSleep", "minutes": 5} or ' +
    '{"kind": "afterWaking", "minutes": 30} (1-240 minutes, around each night\'s main sleep), ' +
    '{"kind": "workout", "activities": [37]} (HKWorkoutActivityType values or names; null for ' +
    'every workout; with version 2, "location": "indoor" or "outdoor" keeps only workouts the ' +
    "workouts tool's indoor says were there, leaving out those that don't say, e.g. " +
    '{"kind": "workout", "activities": ["Running"], "location": "outdoor"} for outdoor runs), ' +
    '{"kind": "timeOfDay", "from": "00:00", "to": "12:00"} (the local clock; may cross ' +
    'midnight). filter: {"sources": [bundle IDs], "deviceModels": ["Watch"]}.',
  `- bucket, what one point covers (${cardBuckets.join(", ")}): auto (the default) is hours at ` +
    "D, days at W and M, weeks at 6M and months at Y. hour takes ranges D and W; day W, M, 6M " +
    "and Y; week M, 6M and Y; month 6M and Y; night (a point per night) any, and needs a series " +
    "with a sleep window. Sleep windows need night, week or month.",
  `- range, the period it opens on (${cardRanges.join(", ")}): a calendar day, week, month, six ` +
    "months or year. Default W, or the bucket's first.",
  '- formulas, up to 2: {"kind": "movingAverage", "of": "a", "points": 7} (2-30 points) or ' +
    '{"kind": "difference", "of": ["a", "b"]} (a minus b). Hide a series to show only a formula.',
  `- chart: style (${cardChartStyles.join(", ")}; default the type's), goal ({"value": 10000}, ` +
    "in the lead series' unit).",
  "Examples:",
  ...Object.entries(cardSpecExamples).map(([what, spec]) => `- ${what}: ${JSON.stringify(spec)}`),
].join("\n");

const cardSpecInputJsonSchema = (() => {
  const document = Schema.toJsonSchemaDocument(CardSpecInput, { onExcessProperty: "error" });
  if (Object.keys(document.definitions).length > 0) {
    throw new Error("The card spec's input schema must have no definitions");
  }
  return document.schema;
})();

/**
 * A spec, as an input: any JSON, which the tool checks with `canonicalCardSpec` so every error comes
 * back with its path and how to fix it, but described by the input form's JSON Schema
 * (`CardSpecInput`), which lists every enum.
 */
const specParameter = Schema.Json.check(
  Schema.makeFilter(() => true, {
    toJsonSchema: () => ({
      ...cardSpecInputJsonSchema,
      description:
        "The card spec: JSON as the schema describes, with defaults left out as you like " +
        "(preview_card's description explains it).",
    }),
  }),
);

const cardId = Schema.String.annotate({
  description: "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them.",
});

const cardRange = Schema.optionalKey(
  Schema.Literals(cardRanges).annotate({
    description:
      "The period to run it over: D a calendar day, W a calendar week, M a calendar month, 6M " +
      "six calendar months, Y a calendar year, containing `date`. One of the card's bucket's " +
      "ranges. Defaults to the card's own.",
  }),
);

/**
 * Any string, as the Mac's `lil-health mcp` takes it: the run checks it's a day the tools take
 * (`toolDate`, as the Health tools' `date`), so both servers answer one that isn't alike,
 * `Invalid date: …` (851-3217, 851-4044), rather than this server with its decoding's
 * `Invalid parameters` and the Mac with the tool's message.
 */
const cardDate = Schema.optionalKey(
  Schema.String.annotate({
    description:
      "A day in the period, as YYYY-MM-DD in `timeZone`. Defaults to the period the card's " +
      "page opens on: its latest value's, as its Summary row shows it (today's without one).",
  }),
);

const firstWeekday = Schema.optionalKey(
  Schema.Literals(cardWeekdays).annotate({
    description: "The day weeks start on. Defaults to monday.",
  }),
);

const runParameters = { range: cardRange, date: cardDate, timeZone, firstWeekday };

// -------------------------------------------------------------------------------------------------
// Outputs
// -------------------------------------------------------------------------------------------------

const canonicalSpec = Schema.Record(Schema.String, Schema.Json).annotate({
  description:
    "The card's spec in canonical form, every default filled in (version 1): " +
    "version, display, series, formulas, bucket, range and chart.",
});

export const HealthCardItem = Schema.Struct({
  id: cardId,
  spec: canonicalSpec,
  position: Schema.String.annotate({
    description:
      "Its place on Summary: cards are in ascending order of position (by bytes), then id.",
  }),
  seed: Schema.NullOr(Schema.String).annotate({
    description: "The welcome card it started as (steps, heart_rate…), else null.",
  }),
  createdAt: LocalTime.annotate({ description: "When it was made." }),
  updatedAt: LocalTime.annotate({ description: "When it was last changed or moved." }),
}).annotate({ identifier: "HealthCardItem" });

export const HealthCardPoint = Schema.Struct({
  start: LocalTime.annotate({
    description: "When the bucket starts (a night's is midnight of the day it ends on).",
  }),
  value: Schema.Finite.annotate({ description: "The aggregation over the bucket, in `unit`." }),
  minimum: Schema.Finite.annotate({ description: "The bucket's lowest reading." }),
  maximum: Schema.Finite.annotate({ description: "The bucket's highest reading." }),
  readings: Schema.NullOr(Schema.Int).annotate({
    description: "How many readings it has; null for totals.",
  }),
}).annotate({ identifier: "HealthCardPoint" });

export const HealthCardSeriesData = Schema.Struct({
  id: Schema.String,
  label: Schema.String.annotate({ description: "Its label, or its type's name." }),
  type: Schema.String.annotate({ description: "Its HealthKit type identifier." }),
  aggregation: Schema.String,
  unit: Schema.String.annotate({
    description: "The values' HealthKit unit, e.g. count/min, or count for a count of readings.",
  }),
  hidden: Schema.Boolean,
  points: Schema.Array(HealthCardPoint).annotate({
    description: "One per bucket with a value, oldest first.",
  }),
}).annotate({ identifier: "HealthCardSeriesData" });

export const HealthCardFormulaPoint = Schema.Struct({
  start: LocalTime,
  value: Schema.Finite,
}).annotate({ identifier: "HealthCardFormulaPoint" });

export const HealthCardFormulaData = Schema.Struct({
  id: Schema.String,
  kind: Schema.String.annotate({ description: "movingAverage or difference." }),
  label: Schema.NullOr(Schema.String),
  unit: Schema.String,
  hidden: Schema.Boolean,
  points: Schema.Array(HealthCardFormulaPoint),
}).annotate({ identifier: "HealthCardFormulaData" });

export const HealthCardData = Schema.Struct({
  range: Schema.NullOr(Schema.String).annotate({ description: "The range it was run over." }),
  start: LocalDate.annotate({ description: "The period's first day." }),
  end: LocalDate.annotate({ description: "The period's last day." }),
  timeZone: usedTimeZone,
  firstWeekday: Schema.String,
  bucket: Schema.String.annotate({ description: "The spec's bucket." }),
  grain: Schema.String.annotate({
    description: "What each point covers, once auto is resolved: hour, day, week or month.",
  }),
  series: Schema.Array(HealthCardSeriesData),
  formulas: Schema.Array(HealthCardFormulaData),
  summary: Schema.NullOr(
    Schema.Struct({
      kind: Schema.String.annotate({
        description:
          "What the card's header shows: total, average, dailyAverage, range, lowest, highest, " +
          "first, latest or count.",
      }),
      value: Schema.NullOr(Schema.Finite).annotate({ description: "Null for a range." }),
      minimum: Schema.NullOr(Schema.Finite).annotate({ description: "A range's lowest reading." }),
      maximum: Schema.NullOr(Schema.Finite).annotate({ description: "A range's highest reading." }),
    }),
  ).annotate({ description: "The period's summary, from the lead series; null without data." }),
  goal: Schema.NullOr(Schema.Finite).annotate({
    description: "The goal line's value, in the lead's unit, or null.",
  }),
}).annotate({ identifier: "HealthCardData" });

export const HealthCardsResult = Schema.Struct({
  timeZone: usedTimeZone,
  cards: Schema.Array(HealthCardItem).annotate({ description: "Every card, in Summary's order." }),
});

export const HealthCardDataResult = Schema.Struct({
  card: HealthCardItem,
  data: HealthCardData,
});

export const HealthCardPreviewResult = Schema.Struct({
  spec: canonicalSpec.annotate({
    description: "The spec in canonical form, as it would be saved.",
  }),
  data: HealthCardData,
});

export const HealthCardResult = Schema.Struct({
  timeZone: usedTimeZone,
  card: HealthCardItem,
});

export const HealthCardDeletedResult = Schema.Struct({
  deleted: Schema.String.annotate({ description: "The deleted card's id." }),
});

export const HealthCardPosition = Schema.Struct({
  id: Schema.String,
  position: Schema.String,
}).annotate({ identifier: "HealthCardPosition" });

export const HealthCardOrderResult = Schema.Struct({
  cards: Schema.Array(HealthCardPosition).annotate({
    description: "Every card, in its new order, with its position.",
  }),
});

// -------------------------------------------------------------------------------------------------
// The tools
// -------------------------------------------------------------------------------------------------

const annotated = <T extends Tool.Any>(
  tool: T,
  title: string,
  hints: {
    readonly readOnly: boolean;
    readonly destructive: boolean;
    readonly idempotent: boolean;
  },
): T =>
  tool
    .annotate(Tool.Title, title)
    .annotate(Tool.Readonly, hints.readOnly)
    .annotate(Tool.Destructive, hints.destructive)
    .annotate(Tool.Idempotent, hints.idempotent)
    .annotate(Tool.OpenWorld, false) as T;

const reads = { readOnly: true, destructive: false, idempotent: true };

/** What the write tools say about the scope they need. */
const writeNote =
  "Needs the person to have allowed this agent to manage cards; it never changes Health data. " +
  "The change syncs to their Mac and iPhone.";

export const ListCards = annotated(
  Tool.make("list_cards", {
    description:
      "Lists the cards on lil health's Summary, in order: each card's id, spec (what it charts " +
      "and how it looks), position and when it was made and changed. Use get_card for a card's " +
      "data.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthCardsResult,
    failure: HealthToolError,
  }),
  "List Cards",
  reads,
);

export const GetCard = annotated(
  Tool.make("get_card", {
    description:
      "A card and its data: its spec run over a period of the person's Health data, as the " +
      "card's page shows it, with each series' points, its formulas and the period's summary.",
    parameters: Schema.Struct({ id: cardId, ...runParameters }),
    success: HealthCardDataResult,
    failure: HealthToolError,
  }),
  "Get Card",
  reads,
);

export const PreviewCard = annotated(
  Tool.make("preview_card", {
    description:
      "Checks a draft card spec and runs it over the person's Health data, without saving " +
      "anything: start here to make a card. If the spec has errors, the call fails listing " +
      "every one with its path and how to fix it; otherwise it returns the canonical spec and " +
      "the data the card would show. Fix and preview again until it's right, then create_card " +
      `(or update_card) with the spec.\n\n${specGuide}`,
    parameters: Schema.Struct({ spec: specParameter, ...runParameters }),
    success: HealthCardPreviewResult,
    failure: HealthToolError,
  }),
  "Preview Card",
  reads,
);

export const CreateCard = annotated(
  Tool.make("create_card", {
    description:
      "Adds a card to the end of lil health's Summary, from a spec (preview_card describes " +
      `specs: preview it first). A person can have up to ${maxCards} cards. Fails listing ` +
      `every error if the spec has any. ${writeNote}`,
    parameters: Schema.Struct({ spec: specParameter, timeZone }),
    success: HealthCardResult,
    failure: HealthToolError,
  }),
  "Create Card",
  { readOnly: false, destructive: false, idempotent: false },
);

export const UpdateCard = annotated(
  Tool.make("update_card", {
    description:
      "Replaces a card's spec with a new one, keeping its place on Summary (preview_card " +
      "describes specs: preview it first). Give the whole spec, not only what changes: " +
      `get_card or list_cards has the current one. ${writeNote}`,
    parameters: Schema.Struct({ id: cardId, spec: specParameter, timeZone }),
    success: HealthCardResult,
    failure: HealthToolError,
  }),
  "Update Card",
  { readOnly: false, destructive: true, idempotent: true },
);

export const DeleteCard = annotated(
  Tool.make("delete_card", {
    description:
      "Deletes a card from lil health's Summary, on every device. Its Health data stays. " +
      writeNote,
    parameters: Schema.Struct({ id: cardId }),
    success: HealthCardDeletedResult,
    failure: HealthToolError,
  }),
  "Delete Card",
  { readOnly: false, destructive: true, idempotent: true },
);

export const ReorderCards = annotated(
  Tool.make("reorder_cards", {
    description:
      "Puts lil health's Summary cards in a new order: give every card's id once, in the order " +
      `you want (list_cards lists them). Only cards whose place changes are written. ${writeNote}`,
    parameters: Schema.Struct({
      ids: Schema.Array(Schema.String)
        .check(Schema.isMaxLength(storeMaxCards))
        .annotate({ description: "Every card's id, each once, in the new order." }),
    }),
    success: HealthCardOrderResult,
    failure: HealthToolError,
  }),
  "Reorder Cards",
  { readOnly: false, destructive: false, idempotent: true },
);

export const CardsToolkit = Toolkit.make(
  ListCards,
  GetCard,
  PreviewCard,
  CreateCard,
  UpdateCard,
  DeleteCard,
  ReorderCards,
);

/** The name each tool's output schema has in `openapi.json`, as `healthToolResultNames`. */
export const cardToolResultNames: Record<keyof typeof CardsToolkit.tools, string> = {
  list_cards: "HealthCardsResult",
  get_card: "HealthCardDataResult",
  preview_card: "HealthCardPreviewResult",
  create_card: "HealthCardResult",
  update_card: "HealthCardResult",
  delete_card: "HealthCardDeletedResult",
  reorder_cards: "HealthCardOrderResult",
};

/** Handlers for every card tool, as an implementation provides them (`CardsToolkit.toLayer`). */
export type CardToolHandlers = Toolkit.HandlersFrom<typeof CardsToolkit.tools>;

/** Handlers that die for every card tool, for listing the tools, which never calls them. */
export const unimplementedCardTools = Object.fromEntries(
  Object.keys(CardsToolkit.tools).map((name) => [
    name,
    () => Effect.die(`The ${name} tool isn't implemented here`),
  ]),
) as unknown as CardToolHandlers;
