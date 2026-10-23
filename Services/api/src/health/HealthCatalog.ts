import { Schema } from "effect";
// Generated from the Swift catalog (LilPackage/Sources/Health/HealthCatalog), its source of truth,
// by scripts/generate-health-catalog, which scripts/format runs (851-2857).
import catalogJson from "../../health-catalog.json" with { type: "json" };

// The Health catalog, as the Mac has it: every type lil health syncs, with the name Health shows,
// its Browse category, and a quantity type's unit and aggregation style; and the names of workout
// activities. The Swift catalog is checked against HealthKit itself, so the server reads a copy of
// it rather than keeping its own. The schemas below follow the Swift enums: a case added there
// fails to decode here until it's added too (test/health/HealthCatalog.test.ts).

/** A Browse category of iPad Health (`HealthCategory`). */
export const HealthCategory = Schema.Literals([
  "activity",
  "bodyMeasurements",
  "cycleTracking",
  "hearing",
  "heart",
  "medications",
  "mentalWellbeing",
  "mobility",
  "nutrition",
  "respiratory",
  "sleep",
  "symptoms",
  "vitals",
  "otherData",
]);
export type HealthCategory = typeof HealthCategory.Type;

/**
 * How HealthKit combines a quantity type's samples (`HKQuantityAggregationStyle`): `cumulative`
 * ones add up (steps, energy), so totals are sums; the discrete ones average, plainly
 * (`discreteArithmetic`: weight), weighted by the time between samples
 * (`discreteTemporallyWeighted`: heart rate), or as an equivalent continuous level
 * (`discreteEquivalentContinuousLevel`: sound levels).
 */
export const HealthAggregation = Schema.Literals([
  "cumulative",
  "discreteArithmetic",
  "discreteTemporallyWeighted",
  "discreteEquivalentContinuousLevel",
]);
export type HealthAggregation = typeof HealthAggregation.Type;

export const HealthCatalogType = Schema.Struct({
  /** HealthKit's identifier, e.g. `HKQuantityTypeIdentifierStepCount`. */
  id: Schema.String,
  /** The name Health shows, e.g. "Steps". */
  name: Schema.String,
  kind: Schema.Literals([
    "quantity",
    "category",
    "correlation",
    "characteristic",
    "workout",
    "workoutRoute",
    "activitySummary",
    "heartbeatSeries",
    "electrocardiogram",
    "audiogram",
    "stateOfMind",
    "scoredAssessment",
    "medication",
    "medicationDoseEvent",
    "visionPrescription",
    "document",
  ]),
  /** The Browse category whose screen shows the type. Null for characteristics. */
  category: Schema.NullOr(HealthCategory),
  /** Other Browse categories that also list the type (e.g. Heart Rate under Vitals). */
  alsoListedIn: Schema.Array(HealthCategory),
  /** The `HKUnit` string lil health stores a quantity type in. Null for other kinds. */
  unit: Schema.NullOr(Schema.String),
  /** A quantity type's aggregation style. Null for other kinds. */
  aggregation: Schema.NullOr(HealthAggregation),
  /**
   * How the apps chart a quantity type (`HealthDataType.ChartStyle`, 851-3097): `bars` of totals,
   * `ranges` from each period's lowest to highest reading, `dots` of each period's average, or a
   * `line` through them. Null for other kinds.
   */
  chartStyle: Schema.NullOr(Schema.Literals(["bars", "ranges", "dots", "line"])),
  /** The iOS version that introduced the type, e.g. "17.0". */
  introduced: Schema.String.check(Schema.isPattern(/^\d+\.\d+$/)),
  readAuthorization: Schema.Literals(["standard", "perObject", "throughComponents", "unavailable"]),
});
export type HealthCatalogType = typeof HealthCatalogType.Type;

const HealthCatalogFile = Schema.Struct({
  categories: Schema.Array(Schema.Struct({ id: HealthCategory, name: Schema.String })),
  types: Schema.Array(HealthCatalogType),
  workoutActivities: Schema.Array(
    Schema.Struct({
      /** `HKWorkoutActivityType`'s raw value. */
      activityType: Schema.Int,
      name: Schema.String,
    }),
  ),
  otherWorkoutActivityName: Schema.String,
});

const catalog = Schema.decodeUnknownSync(HealthCatalogFile)(catalogJson);
const typesById = new Map(catalog.types.map((type) => [type.id, type]));
const categoryNames = new Map(catalog.categories.map(({ id, name }) => [id, name]));
const activityNames = new Map(
  catalog.workoutActivities.map(({ activityType, name }) => [activityType, name]),
);

/** Every type lil health syncs, by category in Browse's order, then characteristics last. */
export const healthCatalogTypes: ReadonlyArray<HealthCatalogType> = catalog.types;

/** A type by its HealthKit identifier, or undefined if the catalog doesn't know it. */
export const healthCatalogType = (id: string): HealthCatalogType | undefined => typesById.get(id);

/** The categories in the order Browse lists them. */
export const healthCategories: ReadonlyArray<HealthCategory> = catalog.categories.map(
  ({ id }) => id,
);

/** The name Health shows for a category, e.g. "Body Measurements". */
export const healthCategoryName = (category: HealthCategory): string =>
  categoryNames.get(category) ?? category;

/** How Health names a workout's activity (`HKWorkoutActivityType`'s raw value), e.g. "Running". */
export const workoutActivityName = (activityType: number): string =>
  activityNames.get(activityType) ?? catalog.otherWorkoutActivityName;
