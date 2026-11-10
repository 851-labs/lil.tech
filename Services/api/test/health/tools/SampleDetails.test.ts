import { assert, describe, it } from "@effect/vitest";
import { DateTime } from "effect";
import { sampleDetails } from "../../../src/health/tools/SampleDetails.ts";

// What `samples` reads of a sample's metadata at its edges (851-4166): units it converts and
// those it doesn't, enums' cases out of range or not set, Booleans written as numbers, and
// columns that aren't objects. The Mac's `SampleDetailsTests` reads the same inputs into the same
// fields. Synthetic data only.

const utc = DateTime.zoneMakeNamedUnsafe("UTC");

const metadata = {
  HKHeartRateEventThreshold: "2 count/s",
  HKMetadataKeyAudioExposureLevel: "85.5 dBASPL",
  HKMetadataKeyAudioExposureDuration: "1.5 hr",
  HKMetadataKeyHeadphoneGain: "3 dB",
  HKBodyTemperatureSensorLocation: 11,
  HKMetadataKeyHeartRateRecoveryTestType: 4,
  HKMetadataKeyHeartRateRecoveryActivityType: 37,
  HKMetadataKeyHeartRateRecoveryActivityDuration: "12 min",
  HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate: "162 count/min",
  HKVO2MaxValue: "28.4 mL/min·kg",
  HKLowCardioFitnessEventThreshold: "30 mL/min·kg",
  HKMetadataKeyDevicePlacementSide: 0,
  HKMetadataKeyWaterSalinity: 2,
  HKMetadataKeyMaximumLightIntensity: "12.5 klx",
  HKPhysicalEffortEstimationType: 1.5,
  HKActivityType: 52,
  HKMetadataKeyQuantityClampedToLowerBound: true,
  HKWasTakenInLab: 1,
  HKMenstrualCycleStart: true,
  HKSexualActivityProtectionUsed: false,
  HKFoodType: "Oatmeal",
  HKDateOfEarliestDataUsedForEstimate: -1,
  HKMetadataKeyHeartRateMotionContext: 0,
  HKMetadataKeyUserMotionContext: 2,
  HKAlgorithmVersion: true,
  HKInsulinDeliveryReason: -1,
  HKBloodGlucoseMealTime: "1",
};

describe("sampleDetails", () => {
  it("reads each key it knows, and leaves out what it can't read", () => {
    const details = sampleDetails(
      {
        // An Apple device's own bundle ID, in capitals: it names the device, so it's left out.
        sourceBundleId: "com.apple.health.ABCDEF01-2345-4678-9ABC-DEF012345678",
        sourceRevision: '"not an object"',
        device: '["not an object"]',
        metadata: JSON.stringify(metadata),
      },
      utc,
    );
    assert.deepStrictEqual(details, {
      heartRateEventThreshold: 120,
      audioExposureLevel: 85.5,
      audioExposureDuration: 5400,
      sensorLocation: "forehead",
      heartRateRecoveryTestType: "stepTest",
      heartRateRecoveryActivity: "Running",
      heartRateRecoveryActivityDuration: 720,
      maxObservedRecoveryHeartRate: 162,
      vo2Max: 28.4,
      lowCardioFitnessThreshold: 30,
      waterSalinity: "saltWater",
      maximumLightIntensity: 12500,
      activity: "Walking",
      clampedToLowerBound: true,
      takenInLab: true,
      menstrualCycleStart: true,
      protectionUsed: false,
      food: "Oatmeal",
      userMotionContext: "active",
    });
  });

  it("is empty for a sample with nothing to say", () => {
    assert.deepStrictEqual(
      sampleDetails(
        {
          sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
          sourceRevision: null,
          device: null,
          metadata: null,
        },
        utc,
      ),
      {},
    );
  });
});
