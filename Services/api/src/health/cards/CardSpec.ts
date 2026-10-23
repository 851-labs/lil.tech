import { Schema } from "effect";
import { healthCatalogTypes, workoutActivities } from "../HealthCatalog.ts";
import { codePointCount } from "./CardJson.ts";

// The card spec, version 1, as the server reads it (851-3202, `docs/decisions/cards.md`, The card
// spec, v1). The Swift `HealthCards` module is its source of truth: the lists below are its, and
// `CardSpec`'s JSON Schema must equal the one it generates (`card-spec.schema.json`, a test), so a
// list that drifts fails. The rules a schema can't express are `CardSpecValidator.ts`'s.

/** The spec version apps and tools write. */
export const cardSpecVersion = 1;
/** The versions the server reads. It refuses a spec of any other (`unsupportedVersion`). */
export const readableCardSpecVersions: ReadonlyArray<number> = [1];

/** At most this many errors are returned for one spec. */
export const maxCardSpecErrors = 20;
/** The largest spec apps and tools write, in bytes of its compact JSON (UTF-8). */
export const maxCardSpecBytes = 8 * 1024;
/**
 * The largest the store keeps: a backstop, so two JSON writers' few bytes of difference never get
 * a push refused.
 */
export const storeMaxCardSpecBytes = 16 * 1024;
/** The most cards apps and tools let an account have. */
export const maxCards = 100;
/** The most the store keeps, as a backstop: devices racing past 100 never reach it. */
export const storeMaxCards = 200;

export const maxCardSeries = 4;
export const maxCardFormulas = 2;
export const maxCardVisibleLines = 4;

/** The SF Symbols a card may have (`HealthCards.cardSymbols`), which draw on macOS and iOS. */
export const cardSymbols = [
  // Health's categories, so the seed looks as Summary did.
  "flame.fill",
  "figure",
  "circle.dotted.circle",
  "ear",
  "heart.fill",
  "pills.fill",
  "brain.head.profile",
  "figure.walk.motion",
  "carrot.fill",
  "lungs.fill",
  "bed.double.fill",
  "list.bullet.clipboard",
  "waveform.path.ecg",
  "plus",
  // Body and vitals.
  "heart.text.square.fill",
  "bolt.heart.fill",
  "waveform",
  "drop.fill",
  "thermometer.medium",
  "scalemass.fill",
  "ruler.fill",
  "eye.fill",
  "hand.raised.fill",
  "brain",
  "cross.case.fill",
  // Activity.
  "figure.walk",
  "figure.run",
  "figure.stairs",
  "figure.pool.swim",
  "figure.outdoor.cycle",
  "bicycle",
  "figure.strengthtraining.traditional",
  "figure.mind.and.body",
  "figure.cooldown",
  "bolt.fill",
  "timer",
  "stopwatch.fill",
  // Sleep and time.
  "moon.fill",
  "moon.zzz.fill",
  "zzz",
  "sun.max.fill",
  "sunrise.fill",
  "sunset.fill",
  "clock.fill",
  "alarm.fill",
  // Food.
  "fork.knife",
  "cup.and.saucer.fill",
  "waterbottle.fill",
  "leaf.fill",
  // General.
  "chart.line.uptrend.xyaxis",
  "chart.bar.fill",
  "gauge.with.dots.needle.50percent",
  "star.fill",
  "target",
  "flag.fill",
] as const;

/** A card's color: one of SwiftUI's system colors, by name (`CardColor`). */
export const cardColors = [
  "red",
  "orange",
  "yellow",
  "green",
  "mint",
  "teal",
  "cyan",
  "blue",
  "indigo",
  "purple",
  "pink",
  "brown",
  "gray",
] as const;

/**
 * The units `display.unit` may name, by dimension (`CardDisplayUnit`), with the catalog units of
 * that dimension, which they convert from. Other catalog units have no others to show.
 */
export const cardDisplayUnitDimensions: ReadonlyArray<{
  readonly name: string;
  readonly units: ReadonlyArray<string>;
  readonly catalogUnits: ReadonlyArray<string>;
}> = [
  { name: "mass", units: ["kg", "lb", "st"], catalogUnits: ["kg", "g", "mg", "mcg"] },
  {
    name: "length",
    units: ["cm", "m", "km", "in", "ft", "yd", "mi"],
    catalogUnits: ["m", "cm"],
  },
  { name: "temperature", units: ["degC", "degF"], catalogUnits: ["degC"] },
  { name: "speed", units: ["km/hr", "mi/hr", "m/s"], catalogUnits: ["m/s"] },
  { name: "volume", units: ["mL", "L", "fl_oz_us"], catalogUnits: ["mL", "L"] },
  { name: "energy", units: ["kcal", "kJ"], catalogUnits: ["kcal"] },
];

/** Every unit `display.unit` may name, in the dimensions' order. */
export const cardDisplayUnits = cardDisplayUnitDimensions.flatMap(({ units }) => units);

export const cardAggregations = ["sum", "avg", "min", "max", "first", "latest", "count"] as const;
export type CardAggregation = (typeof cardAggregations)[number];

export const cardWindowKinds = [
  "asleep",
  "beforeSleep",
  "afterWaking",
  "workout",
  "timeOfDay",
] as const;
export type CardWindowKind = (typeof cardWindowKinds)[number];

export const cardFormulaKinds = ["movingAverage", "difference"] as const;
export type CardFormulaKind = (typeof cardFormulaKinds)[number];

export const cardBuckets = ["auto", "hour", "day", "night", "week", "month"] as const;
export type CardBucket = (typeof cardBuckets)[number];

export const cardRanges = ["D", "W", "M", "6M", "Y"] as const;
export type CardRange = (typeof cardRanges)[number];

export const cardChartStyles = ["bars", "ranges", "dots", "line"] as const;
export type CardChartStyle = (typeof cardChartStyles)[number];

/** The ranges a card of a bucket may open on and offer. */
export const bucketRanges: Readonly<Record<CardBucket, ReadonlyArray<CardRange>>> = {
  auto: cardRanges,
  hour: ["D", "W"],
  day: ["W", "M", "6M", "Y"],
  night: cardRanges,
  week: ["M", "6M", "Y"],
  month: ["6M", "Y"],
};

/** The range a card opens on by default: W, or the bucket's first when it doesn't have W. */
export const defaultRange = (bucket: CardBucket): CardRange => {
  const ranges = bucketRanges[bucket];
  return ranges.includes("W") ? "W" : ranges[0]!;
};

/**
 * The types a series may chart (`HealthCards.chartableTypes`): quantities whose read
 * authorization is standard, the types Metric Detail charts.
 */
export const chartableTypes = healthCatalogTypes.filter(
  (type) => type.kind === "quantity" && type.readAuthorization === "standard",
);

// MARK: - The schema

/** Counts Unicode code points, as the spec's lengths do (not UTF-16 units, as `isMaxLength`). */
const codePoints = (minimum: number, maximum: number) =>
  Schema.makeFilter(
    (text: string) => {
      const length = codePointCount(text);
      return (
        (length >= minimum && length <= maximum) ||
        `Expected ${minimum} to ${maximum} characters, got ${length}`
      );
    },
    { toJsonSchema: () => ({ minLength: minimum, maxLength: maximum }) },
  );

/** A whole number, written as JSON Schema's `integer` (`Schema.isInt` adds safe-integer bounds). */
const whole = Schema.makeFilter(
  (value: number) => Number.isInteger(value) || "Expected a whole number",
  {
    toJsonSchema: () => ({ type: "integer" }),
  },
);

const integerBetween = (minimum: number, maximum: number) =>
  Schema.Finite.check(whole, Schema.isBetween({ minimum, maximum }));

const ID = Schema.String.check(codePoints(1, 16), Schema.isPattern(/^[a-z][a-z0-9]{0,15}$/u));
const Text = Schema.String.check(codePoints(1, 40));
const Label = Schema.NullOr(Text);
const Minutes = integerBetween(1, 240);
const ClockTime = Schema.String.check(
  codePoints(5, 5),
  Schema.isPattern(/^([01][0-9]|2[0-3]):[0-5][0-9]$/u),
);
const FilterList = Schema.NullOr(
  Schema.Array(Schema.String.check(codePoints(1, 200))).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(10),
  ),
);

export const CardWindow = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("asleep") }),
  Schema.Struct({ kind: Schema.Literal("beforeSleep"), minutes: Minutes }),
  Schema.Struct({ kind: Schema.Literal("afterWaking"), minutes: Minutes }),
  Schema.Struct({
    kind: Schema.Literal("workout"),
    /** `HKWorkoutActivityType` raw values, or null for every workout. */
    activities: Schema.NullOr(
      Schema.Array(
        Schema.Literals(workoutActivities.map(({ activityType }) => activityType)).check(whole),
      ).check(Schema.isMinLength(1), Schema.isMaxLength(10), Schema.isUnique()),
    ),
  }),
  Schema.Struct({ kind: Schema.Literal("timeOfDay"), from: ClockTime, to: ClockTime }),
]);
export type CardWindow = typeof CardWindow.Type;

export const CardFilter = Schema.Struct({ sources: FilterList, deviceModels: FilterList });
export type CardFilter = typeof CardFilter.Type;

export const CardSeries = Schema.Struct({
  id: ID,
  /** A chartable quantity type's HealthKit identifier. */
  type: Schema.Literals(chartableTypes.map((type) => type.id)),
  aggregation: Schema.Literals(cardAggregations),
  window: Schema.NullOr(CardWindow),
  filter: Schema.NullOr(CardFilter),
  label: Label,
  hidden: Schema.Boolean,
});
export type CardSeries = typeof CardSeries.Type;

export const CardFormula = Schema.Union([
  Schema.Struct({
    id: ID,
    kind: Schema.Literal("movingAverage"),
    of: ID,
    points: integerBetween(2, 30),
    label: Label,
    hidden: Schema.Boolean,
  }),
  Schema.Struct({
    id: ID,
    kind: Schema.Literal("difference"),
    of: Schema.Array(ID).check(Schema.isMinLength(2), Schema.isMaxLength(2)),
    label: Label,
    hidden: Schema.Boolean,
  }),
]);
export type CardFormula = typeof CardFormula.Type;

/**
 * A spec's structure in canonical form, every field present. Decoding it checks the shape only:
 * `storedCardSpecErrors` is the store's whole check, with the messages agents read.
 */
export const CardSpec = Schema.Struct({
  // `Schema.Literals` of one value renders as `anyOf` of one.
  version: Schema.Literal(cardSpecVersion).check(whole),
  display: Schema.Struct({
    name: Text,
    symbol: Schema.Literals(cardSymbols),
    color: Schema.Literals(cardColors),
    unit: Schema.NullOr(Schema.Literals(cardDisplayUnits)),
  }),
  series: Schema.Array(CardSeries).check(Schema.isMinLength(1), Schema.isMaxLength(maxCardSeries)),
  formulas: Schema.Array(CardFormula).check(
    Schema.isMinLength(0),
    Schema.isMaxLength(maxCardFormulas),
  ),
  bucket: Schema.Literals(cardBuckets),
  range: Schema.Literals(cardRanges),
  chart: Schema.Struct({
    style: Schema.Literals(cardChartStyles),
    goal: Schema.NullOr(
      Schema.Struct({ value: Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0)) }),
    ),
  }),
});
export type CardSpec = typeof CardSpec.Type;
