import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

struct SampleFormatTests {
  @Test
  func metadataKeysReadAsWords() {
    // HealthKit's, with or without `HKMetadataKey` in their value (851-4169).
    #expect(
      SampleFormat.label("HKMetadataKeyHeartRateMotionContext") == "Heart Rate Motion Context")
    #expect(SampleFormat.label("HKHeartRateEventThreshold") == "Heart Rate Event Threshold")
    #expect(SampleFormat.label("HKWasUserEntered") == "Entered by Hand")
    // One with the prefix the SDK doesn't declare reads as words too.
    #expect(SampleFormat.label("HKMetadataKeySomethingNew") == "Something New")
    // Another app's key stays as it is.
    #expect(SampleFormat.label("com.example.reading") == "com.example.reading")
  }

  /// Each kind of value in words (851-4169): enums' cases, Booleans, quantities in the locale's
  /// units, dates on the Mac's clock, a workout activity and the recorded time zone by name.
  /// What the table can't read shows as recorded.
  @Test
  func metadataValuesReadAsWords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    calendar.locale = Locale(identifier: "en_US")
    let locale = Locale(identifier: "en_US")
    var sample = HealthSample(
      id: "a", type: "HKQuantityTypeIdentifierHeartRate", startDate: 1_760_400_000_000,
      endDate: 1_760_400_000_000, sourceName: "Test", sourceBundleID: "com.example")
    sample.metadata = """
      {"HKMetadataKeyHeartRateMotionContext":1,"HKBloodGlucoseMealTime":2,\
      "HKMetadataKeyUserMotionContext":0,"HKInsulinDeliveryReason":7,\
      "HKVO2MaxTestType":2,"HKWasUserEntered":true,"HKIndoorWorkout":0,\
      "HKHeartRateEventThreshold":"120 count/min",\
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate":{"value":151,"unit":"count/min"},\
      "HKWeatherTemperature":{"value":15,"unit":"degC"},\
      "HKElevationAscended":"4250 cm",\
      "HKMetadataKeyAudioExposureDuration":{"value":240,"unit":"s"},\
      "HKAverageMETs":{"value":6.25,"unit":"kcal/hr·kg"},\
      "HKVO2MaxValue":"45.6 mL/min·kg",\
      "HKWeatherHumidity":{"value":0.72,"unit":"%"},\
      "HKMetadataKeyBarometricPressure":{"value":101.325,"unit":"kPa"},\
      "HKDateOfEarliestDataUsedForEstimate":{"date":"2025-10-01T16:00:00.000Z"},\
      "HKActivityType":37,"HKAlgorithmVersion":2,"HKTimeZone":"Asia/Tokyo",\
      "HKFoodType":"Oatmeal","com.example.reading":"7"}
      """
    let rows = SampleFormat.metadata(of: sample, calendar: calendar, locale: locale)
    let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
    #expect(values["HKMetadataKeyHeartRateMotionContext"] == "Sedentary")
    #expect(values["HKBloodGlucoseMealTime"] == "After a Meal")
    #expect(values["HKMetadataKeyUserMotionContext"] == "Not Set")
    // A case HealthKit doesn't define shows as recorded.
    #expect(values["HKInsulinDeliveryReason"] == "7")
    #expect(values["HKVO2MaxTestType"] == "Predicted from Submaximal Exercise")
    #expect(values["HKWasUserEntered"] == "Yes")
    #expect(values["HKIndoorWorkout"] == "No")
    #expect(values["HKHeartRateEventThreshold"] == "120 BPM")
    #expect(values["HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate"] == "151 BPM")
    #expect(values["HKWeatherTemperature"] == "59 °F")
    #expect(values["HKElevationAscended"] == "139 ft")
    #expect(values["HKMetadataKeyAudioExposureDuration"] == "4 min")
    #expect(values["HKAverageMETs"] == "6.25 METs")
    #expect(values["HKVO2MaxValue"] == "45.6 VO₂ max")
    #expect(values["HKWeatherHumidity"] == "72 %")
    // A quantity the tools don't read, in its unit.
    #expect(values["HKMetadataKeyBarometricPressure"] == "101 kPa")
    #expect(
      values["HKDateOfEarliestDataUsedForEstimate"]
        == Date(timeIntervalSince1970: 1_759_334_400).formatted(
          Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)))
    #expect(values["HKActivityType"] == "Running")
    #expect(values["HKAlgorithmVersion"] == "2")
    #expect(values["HKTimeZone"] == "Japan Standard Time")
    #expect(values["HKFoodType"] == "Oatmeal")
    #expect(values["com.example.reading"] == "7")
    // By label.
    #expect(
      rows.map(\.label)
        == rows.map(\.label).sorted { $0.localizedStandardCompare($1) == .orderedAscending })

    // Left out where a Time Zone row says it.
    let shown = SampleFormat.metadata(
      of: sample, timeZoneShown: true, calendar: calendar, locale: locale)
    #expect(!shown.contains { $0.key == "HKTimeZone" })
    #expect(shown.count == rows.count - 1)
  }

  @Test
  func aMomentShowsItsTimeAndASpanBothEnds() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = 1_760_400_000_000
    let moment = HealthSample(
      id: "a", type: "x", startDate: start, endDate: start + 30_000, sourceName: "Test",
      sourceBundleID: "com.example")
    var span = moment
    span.endDate = start + 20 * 60_000
    let time = Date.FormatStyle(calendar: utc, timeZone: utc.timeZone).hour().minute()
    #expect(
      SampleFormat.time(moment, calendar: utc) == Date(unixMilliseconds: start).formatted(time))
    #expect(SampleFormat.time(span, calendar: utc) != SampleFormat.time(moment, calendar: utc))
  }
}
