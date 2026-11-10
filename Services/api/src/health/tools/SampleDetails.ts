import { type DateTime, Option, type Schema } from "effect";
import { type MetadataKey, metadataValue, text } from "../MetadataValues.ts";
import { decodeMetadata, type Metadata } from "../WorkoutMetadata.ts";
import type { HealthSampleSource, sampleDetailFields } from "./HealthToolkit.ts";
import { localTime } from "./ToolTime.ts";

// What the `samples` tool says of a sample beyond its value (851-4166): where it came from (its
// app and version, and its device, which a page lists once each, `SampleSources`), and its
// metadata (only the keys lil health keeps, 851-4152), each key it reads turned into a plain field
// (`sampleDetails`). The Mac reads them alike (`SampleDetails` in `HealthTools`), so the two
// `samples` tools agree (the conformance cases). Every field is left out when the sample doesn't
// have it. Each key's value is read as `MetadataValues.ts` reads it (851-4170): a quantity in a
// unit it isn't read in, or a value of another kind, leaves the field out.

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

/**
 * Each field and the metadata key it's read from, in the order they're read. `sensorLocation` has
 * two keys, heart rate's and body temperature's, and takes the first a sample has.
 */
const metadataFields: ReadonlyArray<readonly [keyof SampleDetails, MetadataKey]> = [
  ["userEntered", "HKWasUserEntered"],
  ["food", "HKFoodType"],
  ["motionContext", "HKMetadataKeyHeartRateMotionContext"],
  ["userMotionContext", "HKMetadataKeyUserMotionContext"],
  ["sensorLocation", "HKHeartRateSensorLocation"],
  ["sensorLocation", "HKBodyTemperatureSensorLocation"],
  ["mealTime", "HKBloodGlucoseMealTime"],
  ["insulinDeliveryReason", "HKInsulinDeliveryReason"],
  ["vo2MaxTestType", "HKVO2MaxTestType"],
  ["vo2Max", "HKVO2MaxValue"],
  ["lowCardioFitnessThreshold", "HKLowCardioFitnessEventThreshold"],
  ["heartRateEventThreshold", "HKHeartRateEventThreshold"],
  ["heartRateRecoveryTestType", "HKMetadataKeyHeartRateRecoveryTestType"],
  ["heartRateRecoveryActivity", "HKMetadataKeyHeartRateRecoveryActivityType"],
  ["heartRateRecoveryActivityDuration", "HKMetadataKeyHeartRateRecoveryActivityDuration"],
  ["maxObservedRecoveryHeartRate", "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate"],
  ["audioExposureLevel", "HKMetadataKeyAudioExposureLevel"],
  ["audioExposureDuration", "HKMetadataKeyAudioExposureDuration"],
  ["headphoneGain", "HKMetadataKeyHeadphoneGain"],
  ["physicalEffortEstimationType", "HKPhysicalEffortEstimationType"],
  ["activity", "HKActivityType"],
  ["placementSide", "HKMetadataKeyDevicePlacementSide"],
  ["deviceCalibrated", "HKMetadataKeyAppleDeviceCalibrated"],
  ["algorithmVersion", "HKAlgorithmVersion"],
  ["clampedToLowerBound", "HKMetadataKeyQuantityClampedToLowerBound"],
  ["clampedToUpperBound", "HKMetadataKeyQuantityClampedToUpperBound"],
  ["referenceRangeLowerLimit", "HKReferenceRangeLowerLimit"],
  ["referenceRangeUpperLimit", "HKReferenceRangeUpperLimit"],
  ["takenInLab", "HKWasTakenInLab"],
  ["waterSalinity", "HKMetadataKeyWaterSalinity"],
  ["maximumLightIntensity", "HKMetadataKeyMaximumLightIntensity"],
  ["menstrualCycleStart", "HKMenstrualCycleStart"],
  ["protectionUsed", "HKSexualActivityProtectionUsed"],
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
        ? metadataValue(metadata, "HKDeviceName")
        : property === "manufacturer"
          ? metadataValue(metadata, "HKDeviceManufacturerName")
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
  for (const [field, key] of metadataFields) {
    if (field in fields) continue;
    const value = metadataValue(metadata, key);
    if (value !== null) fields[field] = value;
  }
  const earliest = metadataValue(metadata, "HKDateOfEarliestDataUsedForEstimate");
  if (earliest !== null && earliest >= estimateDates.from && earliest < estimateDates.to) {
    details.earliestDataUsedForEstimate = localTime(earliest, zone);
  }
  return details;
};
