import { type DateTime, Option, Predicate, type Schema } from "effect";
import { workoutActivityName } from "../HealthCatalog.ts";
import { decodeMetadata, type Metadata } from "../WorkoutMetadata.ts";
import type { HealthSampleSource, sampleDetailFields } from "./HealthToolkit.ts";
import { localTime } from "./ToolTime.ts";

// What the `samples` tool says of a sample beyond its value (851-4166): where it came from (its
// app and version, and its device, which a page lists once each, `SampleSources`), and its
// metadata (only the keys lil health keeps, 851-4152), each key it reads turned into a plain field
// (`sampleDetails`). The Mac reads them alike (`SampleDetails` in `HealthTools`), so the two
// `samples` tools agree (the conformance cases). Every field is left out when the sample doesn't
// have it.
//
// The iPhone writes an `HKQuantity` as its description, a number with 6 significant digits and a
// unit ("120 count/min", `HealthEncoder.json`), until 851-4150 keeps them whole: so quantities are
// rounded to that, and a unit not listed here leaves the field out.

type SampleDetails = {
  -readonly [Field in keyof typeof sampleDetailFields]?: (typeof sampleDetailFields)[Field]["Type"];
};

type SampleSource = {
  -readonly [
    Field in keyof (typeof HealthSampleSource)["Type"]
  ]: (typeof HealthSampleSource)["Type"][Field];
};

/** Where a sample or correlation came from, as stored, its provenance's filled in. */
export interface StoredSource {
  readonly sourceName: string;
  readonly sourceBundleId: string;
  /** JSON, or null. */
  readonly sourceRevision: string | null;
  /** JSON, or null. */
  readonly device: string | null;
  /** JSON, or null. */
  readonly metadata: string | null;
}

/** Apple's own devices' bundle IDs, `com.apple.health.` and the device's UUID. */
const appleDeviceBundleId =
  /^com\.apple\.health\.[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/;

/** A string unless it's blank: only spaces, tabs and line breaks, as the Mac's `unlessBlank`. */
const text = (value: unknown): string | null =>
  Predicate.isString(value) && !/^[ \t\n\r]*$/.test(value) ? value : null;

/** A JSON number, not a Boolean. */
const number = (value: unknown): number | null =>
  Predicate.isNumber(value) && Number.isFinite(value) ? value : null;

/** A Boolean, or 0 or 1 from apps that write it as a number, as `HKIndoorWorkout` is read. */
const boolean = (value: unknown): boolean | null =>
  Predicate.isBoolean(value) ? value : value === 1 ? true : value === 0 ? false : null;

/** The case at an enum's raw value, if it's a whole number with one (not set is null). */
const named =
  (cases: ReadonlyArray<string | null>) =>
  (value: unknown): string | null => {
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

/** A number and a unit, as `HKQuantity.description` writes them: "120 count/min". */
const quantityText = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?) (\S+)$/;

/** A quantity's description in one unit, by the factor of each unit it's read in. */
const quantity =
  (factors: Readonly<Record<string, number>>) =>
  (value: unknown): number | null => {
    if (!Predicate.isString(value)) return null;
    const match = quantityText.exec(value);
    const factor = match === null ? undefined : factors[match[2]!];
    if (match === null || factor === undefined) return null;
    const converted = Number(match[1]) * factor;
    return Number.isFinite(converted) ? converted : null;
  };

const beatsPerMinute = quantity({ "count/min": 1, "count/s": 60 });
const seconds = quantity({ ms: 0.001, s: 1, min: 60, hr: 3600, d: 86400 });
const decibels = quantity({ dBASPL: 1 });
/** VO2 max, in mL/(kg·min): `HKQuantity` writes the unit `mL/min·kg`. */
const vo2Max = quantity({ "mL/min·kg": 1, "mL/kg·min": 1, "ml/min·kg": 1, "ml/kg·min": 1 });
const lux = quantity({ lx: 1, klx: 1000 });

const heartRateTestTypes = [
  null,
  "maxExercise",
  "predictionSubMaxExercise",
  "predictionNonExercise",
];

/**
 * Each field read from one metadata key, in the order they're read. `sensorLocation` has two
 * keys, heart rate's and body temperature's, and takes the first a sample has.
 */
const metadataFields: ReadonlyArray<
  readonly [keyof SampleDetails, string, (value: unknown) => string | number | boolean | null]
> = [
  ["userEntered", "HKWasUserEntered", boolean],
  ["recordedTimeZone", "HKTimeZone", text],
  ["food", "HKFoodType", text],
  ["motionContext", "HKMetadataKeyHeartRateMotionContext", named([null, "sedentary", "active"])],
  ["userMotionContext", "HKMetadataKeyUserMotionContext", named([null, "stationary", "active"])],
  [
    "sensorLocation",
    "HKHeartRateSensorLocation",
    named(["other", "chest", "wrist", "finger", "hand", "earLobe", "foot"]),
  ],
  [
    "sensorLocation",
    "HKBodyTemperatureSensorLocation",
    named([
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
  ],
  ["mealTime", "HKBloodGlucoseMealTime", named([null, "preprandial", "postprandial"])],
  ["insulinDeliveryReason", "HKInsulinDeliveryReason", named([null, "basal", "bolus"])],
  ["vo2MaxTestType", "HKVO2MaxTestType", named([...heartRateTestTypes, "predictionStepTest"])],
  ["vo2Max", "HKVO2MaxValue", vo2Max],
  ["lowCardioFitnessThreshold", "HKLowCardioFitnessEventThreshold", vo2Max],
  ["heartRateEventThreshold", "HKHeartRateEventThreshold", beatsPerMinute],
  [
    "heartRateRecoveryTestType",
    "HKMetadataKeyHeartRateRecoveryTestType",
    named([...heartRateTestTypes, "stepTest"]),
  ],
  ["heartRateRecoveryActivity", "HKMetadataKeyHeartRateRecoveryActivityType", activityName],
  ["heartRateRecoveryActivityDuration", "HKMetadataKeyHeartRateRecoveryActivityDuration", seconds],
  [
    "maxObservedRecoveryHeartRate",
    "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate",
    beatsPerMinute,
  ],
  ["audioExposureLevel", "HKMetadataKeyAudioExposureLevel", decibels],
  ["audioExposureDuration", "HKMetadataKeyAudioExposureDuration", seconds],
  ["headphoneGain", "HKMetadataKeyHeadphoneGain", decibels],
  [
    "physicalEffortEstimationType",
    "HKPhysicalEffortEstimationType",
    named([null, "activityLookup", "deviceSensed"]),
  ],
  ["activity", "HKActivityType", activityName],
  ["placementSide", "HKMetadataKeyDevicePlacementSide", named([null, "left", "right", "central"])],
  ["deviceCalibrated", "HKMetadataKeyAppleDeviceCalibrated", boolean],
  ["algorithmVersion", "HKAlgorithmVersion", number],
  ["clampedToLowerBound", "HKMetadataKeyQuantityClampedToLowerBound", boolean],
  ["clampedToUpperBound", "HKMetadataKeyQuantityClampedToUpperBound", boolean],
  ["referenceRangeLowerLimit", "HKReferenceRangeLowerLimit", number],
  ["referenceRangeUpperLimit", "HKReferenceRangeUpperLimit", number],
  ["takenInLab", "HKWasTakenInLab", boolean],
  ["waterSalinity", "HKMetadataKeyWaterSalinity", named([null, "freshWater", "saltWater"])],
  ["maximumLightIntensity", "HKMetadataKeyMaximumLightIntensity", lux],
  ["menstrualCycleStart", "HKMenstrualCycleStart", boolean],
  ["protectionUsed", "HKSexualActivityProtectionUsed", boolean],
];

/** `HKDevice`'s properties the tool shows, in order: those lil health keeps (851-4152). */
const deviceProperties = [
  "name",
  "manufacturer",
  "model",
  "hardwareVersion",
  "firmwareVersion",
  "softwareVersion",
] as const;

type SampleDevice = { -readonly [Property in (typeof deviceProperties)[number]]?: string };

/**
 * The device's properties it has, else the device's name and manufacturer from the metadata,
 * which apps without an `HKDevice` write; undefined without any.
 */
const sampleDevice = (device: Metadata | null, metadata: Metadata | null) => {
  const result: SampleDevice = {};
  for (const property of deviceProperties) {
    const value =
      text(device?.[property]) ??
      (property === "name"
        ? text(metadata?.["HKDeviceName"])
        : property === "manufacturer"
          ? text(metadata?.["HKDeviceManufacturerName"])
          : null);
    if (value !== null) result[property] = value;
  }
  return Object.keys(result).length === 0 ? undefined : result;
};

/**
 * The dates an estimate's earliest data is shown for, 1970 to 2999, so both servers write them
 * alike (HealthKit is from 2014); a date outside them is left out.
 */
const estimateDates = { from: 0, to: 32_503_680_000_000 } as const;

/** A JSON column as an object, or null if it's null or isn't one. */
export const jsonObject = (json: string | null): Metadata | null =>
  json === null ? null : Option.getOrNull(decodeMetadata(json));

/**
 * A page's sources: each sample's app, version and device, listed once each in the order they
 * first appear, so a page of a Watch's readings doesn't repeat them. Source revisions and devices
 * repeat across a page, so each is read once.
 */
export class SampleSources {
  readonly sources: Array<SampleSource> = [];
  readonly #indexes = new Map<string, number>();
  readonly #parsed = new Map<string, Metadata | null>();

  #object(json: string | null): Metadata | null {
    if (json === null) return null;
    if (!this.#parsed.has(json)) this.#parsed.set(json, jsonObject(json));
    return this.#parsed.get(json)!;
  }

  /** The index in `sources` of where `stored` came from, `metadata` its metadata. */
  indexOf(stored: StoredSource, metadata: Metadata | null): number {
    const source: SampleSource = { name: stored.sourceName };
    if (!appleDeviceBundleId.test(stored.sourceBundleId)) source.bundleId = stored.sourceBundleId;
    const revision = this.#object(stored.sourceRevision);
    const version = text(revision?.["version"]);
    if (version !== null) source.version = version;
    const productType = text(revision?.["productType"]);
    if (productType !== null) source.productType = productType;
    const os = text(revision?.["operatingSystemVersion"]);
    if (os !== null) source.operatingSystemVersion = os;
    const device = sampleDevice(this.#object(stored.device), metadata);
    if (device !== undefined) source.device = device;
    // Its fields are always set in this order, so equal sources have equal keys.
    const key = JSON.stringify(source);
    let index = this.#indexes.get(key);
    if (index === undefined) {
      index = this.sources.length;
      this.sources.push(source);
      this.#indexes.set(key, index);
    }
    return index;
  }
}

/** What a sample's or correlation's metadata says, in `zone`'s local times. */
export const sampleDetails = (
  metadata: Metadata | null,
  zone: DateTime.TimeZone,
): SampleDetails => {
  const details: SampleDetails = {};
  if (metadata === null) return details;
  const fields = details as Record<string, Schema.Json>;
  for (const [field, key, read] of metadataFields) {
    if (field in fields) continue;
    const value = read(metadata[key]);
    if (value !== null) fields[field] = value;
  }
  const earliest = number(metadata["HKDateOfEarliestDataUsedForEstimate"]);
  if (earliest !== null && earliest >= estimateDates.from && earliest < estimateDates.to) {
    details.earliestDataUsedForEstimate = localTime(earliest, zone);
  }
  return details;
};
