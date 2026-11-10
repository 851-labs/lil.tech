import { Predicate } from "effect";
import { workoutActivityName } from "./HealthCatalog.ts";

// How the Health tools read a metadata key's value (851-4170): one table, `metadataKinds`, of
// each HealthKit key they read and what kind of value it holds (text, a number, a Boolean, an
// enum's case, a workout activity, or a quantity and the unit it's read in), which the `samples`
// and `workout` tools and the cards' workout windows read through `metadataValue`. Every key in
// it is one lil health keeps (`health-catalog.json`'s `metadataKeys`, 851-4152). The Mac reads
// them alike (`HealthMetadataValues` in `HealthCatalog`), so the tools agree (the conformance
// cases).
//
// The iPhone writes an `HKQuantity` as its description, a number with 6 significant digits and a
// unit ("120 count/min", `HealthEncoder.json`), until 851-4150 keeps them whole: so quantities are
// rounded to that, and a unit not listed here gives null.

/** Metadata as HealthKit keys it, `WorkoutMetadata.ts`' `Metadata`. */
type Metadata = Readonly<Record<string, unknown>>;

/** A string unless it's blank: only spaces, tabs and line breaks, as the Mac's `text`. */
export const text = (value: unknown): string | null =>
  Predicate.isString(value) && !/^[ \t\n\r]*$/.test(value) ? value : null;

/** A JSON number, not a Boolean. */
export const number = (value: unknown): number | null =>
  Predicate.isNumber(value) && Number.isFinite(value) ? value : null;

/** A Boolean, or 0 or 1 from apps that write it as a number (`HKIndoorWorkout`, for one). */
export const boolean = (value: unknown): boolean | null =>
  Predicate.isBoolean(value) ? value : value === 1 ? true : value === 0 ? false : null;

/** The case at an enum's raw value, if it's a whole number with one (not set is null). */
export const named = (cases: ReadonlyArray<string | null>, value: unknown): string | null => {
  const raw = number(value);
  return raw !== null && Number.isInteger(raw) && raw >= 0 ? (cases[raw] ?? null) : null;
};

/** A workout activity's name, by its `HKWorkoutActivityType` raw value. */
const activityName = (value: unknown): string | null => {
  const raw = number(value);
  // Whole and below 10^15, as the Mac can make an `Int` of it.
  return raw !== null && Number.isInteger(raw) && Math.abs(raw) < 1e15
    ? workoutActivityName(raw)
    : null;
};

/** Each unit's function: multiplying by its factor. */
const scaled = (factors: Record<string, number>): Readonly<Record<string, Conversion>> =>
  Object.fromEntries(
    Object.entries(factors).map(([unit, factor]) => [unit, (value: number) => value * factor]),
  );

type Conversion = (value: number) => number;

/**
 * What a quantity measures: the unit it's read in, and each unit (`HKUnit`'s unit strings, as
 * `HKQuantity.description` writes them) it's converted from.
 */
export const quantities = {
  length: {
    unit: "m",
    from: scaled({
      mm: 0.001,
      cm: 0.01,
      m: 1,
      km: 1000,
      in: 0.0254,
      ft: 0.3048,
      yd: 0.9144,
      mi: 1609.344,
    }),
  },
  speed: {
    unit: "m/s",
    from: scaled({ "m/s": 1, "km/hr": 1000 / 3600, "mi/hr": 1609.344 / 3600, "ft/s": 0.3048 }),
  },
  /** METs: `kcal/hr·kg`, as `HKQuantity.description` writes the unit (with a middle dot). */
  mets: {
    unit: "kcal/hr·kg",
    from: scaled({ "kcal/hr·kg": 1, "kcal/(kg·hr)": 1, "kcal/(hr·kg)": 1 }),
  },
  temperature: {
    unit: "degC",
    from: {
      degC: (value: number) => value,
      degF: (value: number) => ((value - 32) * 5) / 9,
      K: (value: number) => value - 273.15,
    },
  },
  /**
   * A percent, from 0 to 100. Apple's Workout app writes humidity 100 times too large (a quantity
   * of 72 percent units for 72%, described as "7200 %"), so a value over 100 is divided by 100.
   */
  humidity: { unit: "%", from: { "%": (value: number) => (value > 100 ? value / 100 : value) } },
  heartRate: { unit: "count/min", from: scaled({ "count/min": 1, "count/s": 60 }) },
  duration: { unit: "s", from: scaled({ ms: 0.001, s: 1, min: 60, hr: 3600, d: 86400 }) },
  soundLevel: { unit: "dBASPL", from: scaled({ dBASPL: 1 }) },
  /** VO2 max, in mL/(kg·min): `HKQuantity` writes the unit `mL/min·kg`. */
  vo2Max: {
    unit: "mL/kg·min",
    from: scaled({ "mL/min·kg": 1, "mL/kg·min": 1, "ml/min·kg": 1, "ml/kg·min": 1 }),
  },
  illuminance: { unit: "lx", from: scaled({ lx: 1, klx: 1000 }) },
} as const satisfies Record<
  string,
  { readonly unit: string; readonly from: Readonly<Record<string, Conversion>> }
>;

export type Quantity = keyof typeof quantities;

/** A number and a unit, as `HKQuantity.description` writes them: "120 count/min", "4250 cm". */
const quantityText = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?) (\S+)$/;

/** A quantity's description in `quantity`'s unit, or null in a unit it isn't read in. */
export const quantity = (measures: Quantity, value: unknown): number | null => {
  if (!Predicate.isString(value)) return null;
  const match = quantityText.exec(value);
  const convert: Conversion | undefined =
    match === null
      ? undefined
      : (quantities[measures].from as Record<string, Conversion>)[match[2]!];
  if (match === null || convert === undefined) return null;
  const converted = convert(Number(match[1]));
  return Number.isFinite(converted) ? converted : null;
};

/** What a metadata key's value is. */
export type MetadataKind =
  | { readonly kind: "text" }
  | { readonly kind: "number" }
  | { readonly kind: "boolean" }
  /** An enum, by its raw value: each case's name, null for those that say nothing. */
  | { readonly kind: "enum"; readonly cases: ReadonlyArray<string | null> }
  /** An `HKWorkoutActivityType`'s raw value, read as the activity's name. */
  | { readonly kind: "activity" }
  | { readonly kind: "quantity"; readonly quantity: Quantity };

const textKind = { kind: "text" } as const;
const numberKind = { kind: "number" } as const;
const booleanKind = { kind: "boolean" } as const;
const activityKind = { kind: "activity" } as const;
const enumKind = (cases: ReadonlyArray<string | null>) => ({ kind: "enum", cases }) as const;
const quantityKind = (measures: Quantity) => ({ kind: "quantity", quantity: measures }) as const;

const heartRateTestTypes = [
  null,
  "maxExercise",
  "predictionSubMaxExercise",
  "predictionNonExercise",
];

/** `HKWorkoutSwimmingLocationType`'s cases, by raw value; 0 (unknown) is null. */
export const swimmingLocations = [null, "pool", "openWater"];

/** Each metadata key the Health tools read, and what kind of value it holds. */
export const metadataKinds = {
  // Samples (851-4166)
  HKWasUserEntered: booleanKind,
  HKTimeZone: textKind,
  HKFoodType: textKind,
  HKMetadataKeyHeartRateMotionContext: enumKind([null, "sedentary", "active"]),
  HKMetadataKeyUserMotionContext: enumKind([null, "stationary", "active"]),
  HKHeartRateSensorLocation: enumKind([
    "other",
    "chest",
    "wrist",
    "finger",
    "hand",
    "earLobe",
    "foot",
  ]),
  HKBodyTemperatureSensorLocation: enumKind([
    "other",
    "armpit",
    "body",
    "ear",
    "finger",
    "gastroIntestinal",
    "mouth",
    "rectum",
    "toe",
    "earDrum",
    "temporalArtery",
    "forehead",
  ]),
  HKBloodGlucoseMealTime: enumKind([null, "preprandial", "postprandial"]),
  HKInsulinDeliveryReason: enumKind([null, "basal", "bolus"]),
  HKVO2MaxTestType: enumKind([...heartRateTestTypes, "predictionStepTest"]),
  HKVO2MaxValue: quantityKind("vo2Max"),
  HKLowCardioFitnessEventThreshold: quantityKind("vo2Max"),
  HKHeartRateEventThreshold: quantityKind("heartRate"),
  HKMetadataKeyHeartRateRecoveryTestType: enumKind([...heartRateTestTypes, "stepTest"]),
  HKMetadataKeyHeartRateRecoveryActivityType: activityKind,
  HKMetadataKeyHeartRateRecoveryActivityDuration: quantityKind("duration"),
  HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate: quantityKind("heartRate"),
  HKMetadataKeyAudioExposureLevel: quantityKind("soundLevel"),
  HKMetadataKeyAudioExposureDuration: quantityKind("duration"),
  HKMetadataKeyHeadphoneGain: quantityKind("soundLevel"),
  HKPhysicalEffortEstimationType: enumKind([null, "activityLookup", "deviceSensed"]),
  HKActivityType: activityKind,
  HKMetadataKeyDevicePlacementSide: enumKind([null, "left", "right", "central"]),
  HKMetadataKeyAppleDeviceCalibrated: booleanKind,
  HKAlgorithmVersion: numberKind,
  HKDateOfEarliestDataUsedForEstimate: numberKind,
  HKMetadataKeyQuantityClampedToLowerBound: booleanKind,
  HKMetadataKeyQuantityClampedToUpperBound: booleanKind,
  HKReferenceRangeLowerLimit: numberKind,
  HKReferenceRangeUpperLimit: numberKind,
  HKWasTakenInLab: booleanKind,
  HKMetadataKeyWaterSalinity: enumKind([null, "freshWater", "saltWater"]),
  HKMetadataKeyMaximumLightIntensity: quantityKind("illuminance"),
  HKMenstrualCycleStart: booleanKind,
  HKSexualActivityProtectionUsed: booleanKind,
  HKDeviceName: textKind,
  HKDeviceManufacturerName: textKind,
  // Workouts, their activities and events (851-4015, 851-4165)
  HKIndoorWorkout: booleanKind,
  HKSwimmingLocationType: enumKind(swimmingLocations),
  HKWorkoutBrandName: textKind,
  HKElevationAscended: quantityKind("length"),
  HKElevationDescended: quantityKind("length"),
  HKAverageSpeed: quantityKind("speed"),
  HKMaximumSpeed: quantityKind("speed"),
  HKAverageMETs: quantityKind("mets"),
  HKLapLength: quantityKind("length"),
  HKSWOLFScore: numberKind,
  /** `HKWeatherCondition`'s cases, without their prefix; 0 (none) is null. */
  HKWeatherCondition: enumKind([
    null,
    "clear",
    "fair",
    "partlyCloudy",
    "mostlyCloudy",
    "cloudy",
    "foggy",
    "haze",
    "windy",
    "blustery",
    "smoky",
    "dust",
    "snow",
    "hail",
    "sleet",
    "freezingDrizzle",
    "freezingRain",
    "mixedRainAndHail",
    "mixedRainAndSnow",
    "mixedRainAndSleet",
    "mixedSnowAndSleet",
    "drizzle",
    "scatteredShowers",
    "showers",
    "thunderstorms",
    "tropicalStorm",
    "hurricane",
    "tornado",
  ]),
  HKWeatherTemperature: quantityKind("temperature"),
  HKWeatherHumidity: quantityKind("humidity"),
  /** `HKSwimmingStrokeStyle`'s cases; 0 (unknown) is null. */
  HKSwimmingStrokeStyle: enumKind([
    null,
    "mixed",
    "freestyle",
    "backstroke",
    "breaststroke",
    "butterfly",
    "kickboard",
  ]),
} as const satisfies Record<string, MetadataKind>;

export type MetadataKey = keyof typeof metadataKinds;

/** The value a kind of metadata is read as. */
type ValueOf<Kind extends MetadataKind> = Kind extends { kind: "boolean" }
  ? boolean
  : Kind extends { kind: "number" | "quantity" }
    ? number
    : string;

/** A value of `kind`, or null if it isn't one. */
export const readMetadataValue = <Kind extends MetadataKind>(
  kind: Kind,
  value: unknown,
): ValueOf<Kind> | null => {
  const read = (): string | number | boolean | null => {
    switch (kind.kind) {
      case "text":
        return text(value);
      case "number":
        return number(value);
      case "boolean":
        return boolean(value);
      case "enum":
        return named(kind.cases, value);
      case "activity":
        return activityName(value);
      case "quantity":
        return quantity(kind.quantity, value);
    }
  };
  return read() as ValueOf<Kind> | null;
};

/** What `metadata` says at `key`, read as the key's kind, or null if it doesn't say. */
export const metadataValue = <Key extends MetadataKey>(
  metadata: Metadata | null | undefined,
  key: Key,
): ValueOf<(typeof metadataKinds)[Key]> | null =>
  readMetadataValue(metadataKinds[key], metadata?.[key]);
