import Foundation
import Testing

@testable import HealthCatalog

// How the Health tools read a metadata value at its edges (851-4170): blank text, Booleans
// written as numbers, enums' raw values out of range or not whole, quantities in both forms
// (`{ value, unit }` and descriptions, 851-4150) in units each quantity is or isn't read in,
// humidity's ×100, and dates in both forms. The server's
// `MetadataValues.test.ts` reads the same inputs alike. Synthetic data only.
@Suite struct HealthMetadataValuesTests {
  /// A value as `JSONSerialization` reads it from `json`, a JSON value.
  private func json(_ json: String) -> Any? {
    let array = try? JSONSerialization.jsonObject(with: Data("[\(json)]".utf8)) as? [Any]
    return array?.first
  }

  private func read(_ kind: HealthMetadataValues.Kind, _ value: String) -> HealthMetadataValues
    .Value?
  {
    HealthMetadataValues.read(kind, json(value))
  }

  @Test func readsOnlyKeysLilHealthKeeps() {
    for key in HealthMetadataValues.kinds.keys {
      #expect(HealthCatalog.keptMetadataKeys.contains(key), "\(key)")
    }
  }

  @Test func readsTextUnlessItsBlank() {
    #expect(read(.text, #""Oatmeal""#) == .text("Oatmeal"))
    #expect(read(.text, #"" a ""#) == .text(" a "))
    // Only spaces, tabs and line breaks are blank: a no-break space isn't.
    #expect(read(.text, #"" ""#) == .text("\u{a0}"))
    for blank in [#""""#, #"" ""#, #"" \t\n\r""#] { #expect(read(.text, blank) == nil) }
    for other in ["1", "true", "null", "{}"] { #expect(read(.text, other) == nil) }
  }

  @Test func readsNumbersNotBooleansOrStrings() {
    #expect(read(.number, "2.5") == .number(2.5))
    #expect(read(.number, "-1") == .number(-1))
    for other in ["true", "false", #""1""#, "null"] { #expect(read(.number, other) == nil) }
    #expect(HealthMetadataValues.read(.number, Double.infinity) == nil)
    #expect(HealthMetadataValues.read(.number, Double.nan) == nil)
  }

  @Test func readsBooleansAndZeroOrOneAsOne() {
    #expect(read(.boolean, "true") == .boolean(true))
    #expect(read(.boolean, "false") == .boolean(false))
    #expect(read(.boolean, "1") == .boolean(true))
    #expect(read(.boolean, "0") == .boolean(false))
    for other in ["2", "-1", "0.5", #""1""#, #""true""#, "null"] {
      #expect(read(.boolean, other) == nil)
    }
  }

  @Test func readsAnEnumsCaseByAWholeRawValueWithOne() throws {
    let salinity = try #require(HealthMetadataValues.kinds["HKMetadataKeyWaterSalinity"])
    #expect(read(salinity, "2") == .text("saltWater"))
    #expect(read(salinity, "1") == .text("freshWater"))
    // 0 is the case that says nothing, 3 is past the last, and the rest aren't whole numbers.
    for other in ["0", "3", "-1", "1.5", #""1""#, "true", "null"] {
      #expect(read(salinity, other) == nil)
    }
  }

  @Test func readsAWorkoutActivitysNameByItsRawValue() {
    #expect(read(.activity, "52") == .text("Walking"))
    // An activity the catalog doesn't name is a workout.
    #expect(read(.activity, "9999") == .text("Workout"))
    for other in ["52.5", "1e16", #""52""#, "true"] { #expect(read(.activity, other) == nil) }
  }

  @Test func readsAQuantitysDescriptionInItsUnit() throws {
    func quantity(_ quantity: HealthMetadataValues.Quantity, _ value: String) -> Double? {
      HealthMetadataValues.quantity(quantity, value)
    }
    #expect(quantity(.heartRate, "120 count/min") == 120)
    #expect(quantity(.heartRate, "2 count/s") == 120)
    #expect(quantity(.length, "4250 cm") == 42.5)
    #expect(quantity(.length, ".5 km") == 500)
    #expect(quantity(.length, "5. m") == 5)
    #expect(quantity(.length, "-1.5e2 m") == -150)
    #expect(quantity(.duration, "1.5 hr") == 5400)
    #expect(quantity(.illuminance, "12.5 klx") == 12500)
    #expect(quantity(.vo2Max, "28.4 mL/min·kg") == 28.4)
    #expect(quantity(.mets, "6.25 kcal/hr·kg") == 6.25)
    #expect(quantity(.temperature, "212 degF") == 100)
    #expect(quantity(.temperature, "0 K") == -273.15)
    let speed = try #require(quantity(.speed, "36 km/hr"))
    #expect(abs(speed - 10) < 1e-12)
  }

  @Test func readsEachQuantityInItsOwnUnitAsItIs() {
    for quantity in HealthMetadataValues.Quantity.allCases {
      #expect(HealthMetadataValues.quantity(quantity, "7 \(quantity.unit)") == 7, "\(quantity)")
    }
  }

  @Test func readsHumidityOver100As100TimesTooLarge() {
    #expect(HealthMetadataValues.quantity(.humidity, "72 %") == 72)
    #expect(HealthMetadataValues.quantity(.humidity, "100 %") == 100)
    #expect(HealthMetadataValues.quantity(.humidity, "7200 %") == 72)
  }

  @Test func leavesOutAQuantityInAnotherUnitOrNotWrittenAsADescription() {
    for other in [
      "120 bpm", "3 dB", "120  count/min", "120count/min", " 120 count/min", "120 count/min ",
      "120", "count/min", "1e400 count/min",
    ] {
      #expect(HealthMetadataValues.quantity(.heartRate, other) == nil, "\(other)")
    }
    for other in ["120", "true", "null"] {
      #expect(read(.quantity(.heartRate), other) == nil)
    }
  }

  @Test func readsAWholeQuantityInItsUnit() throws {
    func quantity(_ quantity: HealthMetadataValues.Quantity, _ value: String) -> Double? {
      HealthMetadataValues.quantity(quantity, json(value))
    }
    #expect(quantity(.length, #"{"value": 84.6012345, "unit": "m"}"#) == 84.6012345)
    #expect(quantity(.length, #"{"value": 123456789, "unit": "m"}"#) == 123_456_789)
    #expect(quantity(.heartRate, #"{"value": 120, "unit": "count/min"}"#) == 120)
    #expect(quantity(.mets, #"{"value": 9.876543, "unit": "kcal/hr·kg"}"#) == 9.876543)
    #expect(quantity(.vo2Max, #"{"value": 45.6789, "unit": "mL/min·kg"}"#) == 45.6789)
    #expect(quantity(.temperature, #"{"value": 15, "unit": "degC"}"#) == 15)
    // A percent is a fraction: 0.555 is 55.5%, and Apple's Workout app's 72 (7200%) is 72%.
    #expect(quantity(.humidity, #"{"value": 0.555, "unit": "%"}"#) == 55.5)
    #expect(quantity(.humidity, #"{"value": 72, "unit": "%"}"#) == 72)
    // Converted from any unit the quantity reads, as a description is.
    #expect(quantity(.length, #"{"value": 25, "unit": "yd"}"#) == 22.86)
    for measures in HealthMetadataValues.Quantity.allCases where measures != .humidity {
      #expect(
        quantity(measures, #"{"value": 7, "unit": "\#(measures.unit)"}"#) == 7, "\(measures)")
    }
  }

  @Test func leavesOutAWholeQuantityInAnotherUnitOrNotValueAndUnit() {
    for other in [
      #"{"value": 120, "unit": "bpm"}"#, #"{"value": "120", "unit": "count/min"}"#,
      #"{"value": true, "unit": "count/min"}"#, #"{"value": null, "unit": "count/min"}"#,
      #"{"value": 120}"#, #"{"unit": "count/min"}"#, #"{"value": 120, "unit": 1}"#,
      #"[120, "count/min"]"#, "{}",
    ] {
      #expect(HealthMetadataValues.quantity(.heartRate, json(other)) == nil, "\(other)")
    }
  }

  @Test func readsADateAsISO8601OrUnixMilliseconds() throws {
    let date = try #require(HealthMetadataValues.kinds["HKDateOfEarliestDataUsedForEstimate"])
    #expect(read(date, "1791763200000") == .number(1_791_763_200_000))
    #expect(read(date, #"{"date": "2026-10-12T00:00:00.123Z"}"#) == .number(1_791_763_200_123))
    #expect(read(date, #"{"date": "2026-10-12T00:00:00Z"}"#) == .number(1_791_763_200_000))
    #expect(
      read(date, #"{"date": "2026-10-12T01:00:00.5+01:00"}"#) == .number(1_791_763_200_500))
    for other in [
      #"{"date": "2026-10-12"}"#, #"{"date": "2026-10-12T00:00:00"}"#,
      #"{"date": "2026-10-12 00:00:00Z"}"#, #"{"date": "2026-10-12T00:00:00.1234Z"}"#,
      #"{"date": 1791763200000}"#, #""2026-10-12T00:00:00Z""#, "{}", "true", "null",
    ] {
      #expect(read(date, other) == nil, "\(other)")
    }
  }

  @Test func readsAKeyFromMetadataOrNilWhenItsMissing() {
    let metadata: [String: Any] = ["HKIndoorWorkout": 1, "HKElevationAscended": "4250 cm"]
    #expect(HealthMetadataValues.value("HKIndoorWorkout", in: metadata) == .boolean(true))
    #expect(HealthMetadataValues.value("HKElevationAscended", in: metadata) == .number(42.5))
    #expect(HealthMetadataValues.value("HKElevationDescended", in: metadata) == nil)
    #expect(HealthMetadataValues.value("HKIndoorWorkout", in: nil) == nil)
  }
}
