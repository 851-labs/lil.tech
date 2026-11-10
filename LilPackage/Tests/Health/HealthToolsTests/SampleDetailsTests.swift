import Foundation
import Testing

@testable import HealthTools

// What `samples` reads of a sample's metadata at its edges (851-4166): units it converts and
// those it doesn't, enums' cases out of range or not set, Booleans written as numbers, and
// columns that aren't objects. The server's `SampleDetails.test.ts` reads the same inputs into
// the same fields. Synthetic data only.
@Suite struct SampleDetailsTests {
  private let time = try! ToolTime(timeZone: "UTC")

  private let metadata = """
    {"HKHeartRateEventThreshold":"2 count/s","HKMetadataKeyAudioExposureLevel":"85.5 dBASPL",
    "HKMetadataKeyAudioExposureDuration":"1.5 hr","HKMetadataKeyHeadphoneGain":"3 dB",
    "HKBodyTemperatureSensorLocation":11,"HKMetadataKeyHeartRateRecoveryTestType":4,
    "HKMetadataKeyHeartRateRecoveryActivityDuration":"12 min",
    "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate":"162 count/min",
    "HKVO2MaxValue":"28.4 mL/min·kg","HKLowCardioFitnessEventThreshold":"30 mL/min·kg",
    "HKMetadataKeyDevicePlacementSide":0,"HKMetadataKeyWaterSalinity":2,
    "HKMetadataKeyMaximumLightIntensity":"12.5 klx","HKPhysicalEffortEstimationType":1.5,
    "HKActivityType":52,"HKMetadataKeyHeartRateRecoveryActivityType":1e16,"HKMetadataKeyQuantityClampedToLowerBound":true,"HKWasTakenInLab":1,
    "HKMenstrualCycleStart":true,"HKSexualActivityProtectionUsed":false,"HKFoodType":"Oatmeal",
    "HKDateOfEarliestDataUsedForEstimate":-1,"HKMetadataKeyHeartRateMotionContext":0,
    "HKMetadataKeyUserMotionContext":2,"HKAlgorithmVersion":true,"HKInsulinDeliveryReason":-1,
    "HKBloodGlucoseMealTime":"1"}
    """

  @Test func readsEachKeyItKnowsAndLeavesOutWhatItCantRead() throws {
    let details = SampleDetails.details(SampleDetails.object(metadata), time: time)
    var expected = HealthSampleDetails()
    expected.heartRateEventThreshold = 120
    expected.audioExposureLevel = 85.5
    expected.audioExposureDuration = 5400
    expected.sensorLocation = "forehead"
    expected.heartRateRecoveryTestType = "stepTest"
    expected.heartRateRecoveryActivityDuration = 720
    expected.maxObservedRecoveryHeartRate = 162
    expected.vo2Max = 28.4
    expected.lowCardioFitnessThreshold = 30
    expected.waterSalinity = "saltWater"
    expected.maximumLightIntensity = 12500
    expected.activity = "Walking"
    expected.clampedToLowerBound = true
    expected.takenInLab = true
    expected.menstrualCycleStart = true
    expected.protectionUsed = false
    expected.food = "Oatmeal"
    expected.userMotionContext = "active"
    #expect(details == expected)
  }

  @Test func isEmptyWithoutMetadata() throws {
    #expect(SampleDetails.details(nil, time: time) == HealthSampleDetails())
    // And its JSON has none of the fields, not even as null.
    let item = HealthSampleItem(
      id: "x", start: "s", end: "e", value: nil, unit: nil, categoryValue: 1, source: "Watch",
      sourceIndex: 0)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? NSDictionary
    let expected: NSDictionary = [
      "id": "x", "start": "s", "end": "e", "value": NSNull(), "unit": NSNull(),
      "categoryValue": 1, "source": "Watch", "sourceIndex": 0,
    ]
    #expect(json == expected)
  }

  @Test func listsEachSourceOnceInTheOrderTheyFirstAppear() {
    var sources = SampleSources()
    let watch = SampleDetails.Stored(
      sourceName: "Test Apple Watch",
      // An Apple device's own bundle ID, in capitals: it names the device, so it's left out.
      sourceBundleID: "com.apple.health.ABCDEF01-2345-4678-9ABC-DEF012345678",
      sourceRevision: #"{"version":"26.1","productType":"Watch7,1"}"#,
      device: #"{"name":"Apple Watch","model":"Watch","localIdentifier":""}"#)
    let app = SampleDetails.Stored(
      sourceName: "Test App", sourceBundleID: "com.example.app",
      sourceRevision: #""not an object""#, device: #"["not an object"]"#)
    let indexes: [Int] = [
      sources.index(of: watch, metadata: nil), sources.index(of: app, metadata: nil),
      sources.index(of: watch, metadata: nil),
      sources.index(
        of: app, metadata: ["HKDeviceName": "Test Meter", "HKDeviceManufacturerName": " "]),
    ]
    #expect(indexes == [0, 1, 0, 2])
    #expect(
      sources.sources == [
        HealthSampleSource(
          name: "Test Apple Watch", version: "26.1", productType: "Watch7,1",
          device: HealthSampleDevice(name: "Apple Watch", model: "Watch")),
        HealthSampleSource(name: "Test App", bundleId: "com.example.app"),
        HealthSampleSource(
          name: "Test App", bundleId: "com.example.app",
          device: HealthSampleDevice(name: "Test Meter")),
      ])
  }
}
