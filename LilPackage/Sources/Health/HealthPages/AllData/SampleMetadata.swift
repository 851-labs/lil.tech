import Foundation
import HealthCatalog
import HealthDatabase
import HealthUI

/// A row of a sample's Metadata section: a key and its value, in words (851-4169).
struct MetadataRow: Equatable {
  /// The key as recorded, which identifies the row.
  var key: String
  var label: String
  var value: String
}

extension SampleFormat {
  /// A sample's metadata as its details show it (851-4169), by label. Each of HealthKit's keys is
  /// named as the metadata allow-list labels it (`HealthMetadataKey.label`), and its value read
  /// as the shared table's kind for it (`HealthMetadataValues.kinds`): an enum's case and a
  /// workout activity by name, a Boolean as Yes or No, a quantity in the unit the Mac shows its
  /// kind in, a date on the Mac's clock, and the recorded time zone by its name. A value its kind
  /// can't read, and a key the table doesn't read, show as recorded (`metadataText`).
  ///
  /// `HKTimeZone` is left out when `timeZoneShown`: the details' Time Zone row (851-4179) says
  /// the same, in words and with the start on its clock.
  static func metadata(
    of sample: HealthSample, timeZoneShown: Bool = false, calendar: Calendar, locale: Locale
  ) -> [MetadataRow] {
    sample.metadataObject
      .filter { !(timeZoneShown && $0.key == timeZoneKey) }
      .map { key, raw in
        MetadataRow(
          key: key, label: label(key),
          value: value(key, raw, in: sample, calendar: calendar, locale: locale)
            ?? HealthSample.metadataText(raw))
      }
      .sorted {
        let order = $0.label.localizedStandardCompare($1.label)
        return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
      }
  }

  static let timeZoneKey = "HKTimeZone"

  /// A metadata key as words: HealthKit's as the allow-list labels it ("Heart Rate Event
  /// Threshold" for `HKHeartRateEventThreshold`), another with `HKMetadataKey` in front as its
  /// constant would read. Other apps' keys are left as they are.
  static func label(_ key: String) -> String {
    if let known = HealthCatalog.healthKitMetadataKeysByKey[key] { return known.label }
    return key.hasPrefix("HKMetadataKey") ? HealthMetadataKey.words(key) : key
  }

  /// A value in words, or nil to show it as recorded.
  private static func value(
    _ key: String, _ raw: Any?, in sample: HealthSample, calendar: Calendar, locale: Locale
  ) -> String? {
    if key == timeZoneKey, let name = HealthMetadataValues.text(raw) {
      return RecordedTimeZone(name, start: sample.start, calendar: calendar)?.name ?? name
    }
    let declared = HealthCatalog.metadataQuantityUnits[key]
    // A pool's length, in the unit it was measured in, as the swim page shows it (851-3176):
    // a 25-yard pool is 25 yd anywhere.
    if case .recorded(let units)? = declared {
      guard let (number, unit) = HealthMetadataValues.quantityParts(raw) else { return nil }
      if units.contains(unit) {
        let shown = MetricFormat.swimmingUnit(yards: unit == "yd", locale: locale)
        return "\(shown.format(number)) \(shown.label)"
      }
      // Another length, in metres.
      guard let meters = HealthMetadataValues.quantity(.length, raw) else { return nil }
      let shown = MetricFormat.swimmingUnit(yards: false, locale: locale)
      return "\(shown.format(meters)) \(shown.label)"
    }
    guard let kind = HealthMetadataValues.kinds[key] else {
      // A quantity the tools don't read (barometric pressure, a slope's grade, a gym machine's
      // distance, a session estimate): its number and unit, in the unit the Mac shows them in.
      guard let declared, let (number, unit) = HealthMetadataValues.quantityParts(raw) else {
        return nil
      }
      // A session estimate is a reading of the sample's own kind, so it's in the sample's unit.
      let typeID = declared == .sample ? sample.type : displayTypes[key] ?? ""
      return quantity(number, unit: unit, typeID: typeID, locale: locale)
    }
    switch kind {
    case .boolean:
      return HealthMetadataValues.boolean(raw).map { $0 ? "Yes" : "No" }
    case .named(let cases):
      // A raw value HealthKit says nothing with: not set, unknown or none.
      return HealthMetadataValues.caseIndex(cases, raw).map { index in
        cases[index].map(words) ?? noneNames[key] ?? "Unknown"
      }
    case .activity, .text:
      return HealthMetadataValues.read(kind, raw)?.string
    // As recorded, without grouping: an algorithm version, a lab's reference limit.
    case .number:
      return HealthMetadataValues.number(raw)?.formatted(
        .number.grouping(.never).precision(.significantDigits(1...12)).locale(locale))
    case .quantity(let quantity):
      return HealthMetadataValues.quantity(quantity, raw).map {
        self.quantity($0, unit: quantity.unit, typeID: "", locale: locale)
      }
    case .date:
      return HealthMetadataValues.date(raw).map {
        Date(timeIntervalSince1970: $0 / 1000).formatted(
          // The style of the details' Start and End.
          Date.FormatStyle(
            locale: calendar.locale ?? locale, calendar: calendar, timeZone: calendar.timeZone))
      }
    }
  }

  /// A metadata quantity, `number` in `unit` (`HKUnit`'s unit string, a percent from 0 to 100),
  /// as the Mac shows its kind: heart rates in BPM, lengths, speeds and temperatures in the
  /// locale's units, durations as Health writes a session's. `typeID` is the sample type whose
  /// unit it's in, if it's a reading of one, else empty.
  static func quantity(_ number: Double, unit: String, typeID: String, locale: Locale) -> String {
    let parts: (number: String, unit: String)
    switch unit {
    // As Health writes a session's (`MetricFormat.duration`), in `locale`.
    case "s" where number.rounded() < 60:
      parts = (Int(number.rounded()).formatted(.number.locale(locale)), "sec")
    case "s":
      parts = (
        (number / 60).formatted(.number.precision(.fractionLength(0...1)).locale(locale)), "min"
      )
    // A barometer's reading, whose tenths matter.
    case "kPa":
      parts = (number.formatted(.number.precision(.fractionLength(0...2)).locale(locale)), unit)
    case "kcal/hr·kg":
      parts = (number.formatted(.number.precision(.fractionLength(0...2)).locale(locale)), "METs")
    // VO2 max, as Health writes Cardio Fitness's.
    case "mL/kg·min", "mL/min·kg":
      parts = MetricFormat.value(number, unit: "ml/(kg*min)", typeID: typeID, locale: locale)
    // `MetricFormat`'s percents are fractions.
    case "%":
      parts = MetricFormat.value(number / 100, unit: unit, typeID: typeID, locale: locale)
    default:
      parts = MetricFormat.value(number, unit: unit, typeID: typeID, locale: locale)
    }
    return parts.unit.isEmpty ? parts.number : "\(parts.number) \(parts.unit)"
  }

  /// The sample type whose units a quantity the tools don't read is shown in, where it isn't a
  /// length's default (m or ft): a gym machine's distance, in km or mi.
  private static let displayTypes = [
    "HKCrossTrainerDistance": "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKIndoorBikeDistance": "HKQuantityTypeIdentifierDistanceCycling",
  ]

  /// What an enum's case that says nothing reads as, where it isn't "Unknown": HealthKit's
  /// `notSet` and `none`.
  private static let noneNames = [
    "HKMetadataKeyHeartRateMotionContext": "Not Set",
    "HKMetadataKeyUserMotionContext": "Not Set",
    "HKWeatherCondition": "None",
  ]

  /// Names a value's case reads better as than its words.
  private static let caseNames = [
    "preprandial": "Before a Meal",
    "postprandial": "After a Meal",
    "maxExercise": "Maximal Exercise",
    "predictionSubMaxExercise": "Predicted from Submaximal Exercise",
    "predictionNonExercise": "Predicted Without Exercise",
    "predictionStepTest": "Predicted from a Step Test",
    "earLobe": "Earlobe",
    "earDrum": "Eardrum",
    "gastroIntestinal": "Gastrointestinal",
  ]

  /// An enum case's name in words: `partlyCloudy` reads "Partly Cloudy".
  static func words(_ name: String) -> String {
    if let known = caseNames[name] { return known }
    let first = name.prefix(1).uppercased() + name.dropFirst()
    return HealthMetadataKey.words(first)
  }
}
