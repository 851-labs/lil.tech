public import Foundation
import HealthCatalog
public import HealthKit

/// Turns HealthKit objects into mutations of the server's health entities
/// (`Services/api/src/health/HealthEntities.ts`): lowercase UUIDs, Unix milliseconds, values in
/// each type's catalog unit, and provenance and metadata as JSON.
public enum HealthEncoder {
  public static let sampleEntity = "health_sample"
  public static let correlationEntity = "health_correlation"
  public static let characteristicEntity = "health_characteristic"
  public static let activitySummaryEntity = "health_activity_summary"

  public struct UnsupportedSample: Error, Equatable {
    public let type: String
  }

  /// A quantity or category sample. `correlation` is the UUID of the correlation it belongs to.
  public static func sample(
    _ sample: HKSample, correlation: UUID? = nil
  ) throws -> HealthMutation {
    var row = provenance(of: sample)
    row["type"] = .string(sample.sampleType.identifier)
    // Left out unless known: a sample read on its own (e.g. systolic blood pressure) mustn't
    // clear the link a correlation upload set, since upserts merge.
    if let correlation { row["correlationId"] = .string(id(correlation)) }
    switch sample {
    case let quantity as HKQuantitySample:
      let unit = try unit(for: quantity.quantityType)
      row["value"] = .number(quantity.quantity.doubleValue(for: unit))
      row["unit"] = .string(unit.unitString)
      row["categoryValue"] = .null
    case let category as HKCategorySample:
      row["value"] = .null
      row["unit"] = .null
      row["categoryValue"] = JSONValue(category.value)
    default:
      throw UnsupportedSample(type: sample.sampleType.identifier)
    }
    return .upsert(sampleEntity, id: id(sample.uuid), row: row)
  }

  /// A correlation, then each of its samples pointing at it.
  public static func correlation(_ correlation: HKCorrelation) throws -> [HealthMutation] {
    var row = provenance(of: correlation)
    row["type"] = .string(correlation.correlationType.identifier)
    let members = try correlation.objects
      .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
      .map { try sample($0, correlation: correlation.uuid) }
    return [.upsert(correlationEntity, id: id(correlation.uuid), row: row)] + members
  }

  /// One day's Activity rings, keyed by its Gregorian date (`YYYY-MM-DD`). `day` is
  /// `summary.dateComponents(for: calendar)`, in the iPhone's calendar, which may not be
  /// Gregorian.
  public static func activitySummary(
    _ summary: HKActivitySummary, day: DateComponents, calendar: Calendar
  ) -> HealthMutation? {
    guard let id = gregorianDay(day, calendar: calendar) else { return nil }
    let moveTime = summary.activityMoveMode == .appleMoveTime
    return .upsert(
      activitySummaryEntity, id: id,
      row: [
        "activeEnergyBurned": .number(summary.activeEnergyBurned.doubleValue(for: .kilocalorie())),
        "activeEnergyBurnedGoal": .number(
          summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())),
        "appleMoveTime": moveTime
          ? .number(summary.appleMoveTime.doubleValue(for: .minute())) : .null,
        "appleMoveTimeGoal": moveTime
          ? .number(summary.appleMoveTimeGoal.doubleValue(for: .minute())) : .null,
        "appleExerciseTime": .number(summary.appleExerciseTime.doubleValue(for: .minute())),
        "appleExerciseTimeGoal": .number(
          summary.exerciseTimeGoal?.doubleValue(for: .minute())
            ?? summary.appleExerciseTimeGoal.doubleValue(for: .minute())),
        "appleStandHours": .number(summary.appleStandHours.doubleValue(for: .count())),
        "appleStandHoursGoal": .number(
          summary.standHoursGoal?.doubleValue(for: .count())
            ?? summary.appleStandHoursGoal.doubleValue(for: .count())),
        "activityMoveMode": activityMoveMode(summary.activityMoveMode),
        "paused": .bool(summary.isPaused),
      ])
  }

  /// A characteristic, keyed by its type identifier.
  public static func characteristic(
    _ type: HKCharacteristicTypeIdentifier, value: JSONValue
  ) -> HealthMutation {
    .upsert(characteristicEntity, id: type.rawValue, row: ["value": value])
  }

  /// Date of birth as `{ "year", "month", "day" }`.
  public static func dateOfBirth(_ components: DateComponents) -> JSONValue {
    .object([
      "year": JSONValue(components.year), "month": JSONValue(components.month),
      "day": JSONValue(components.day),
    ])
  }

  public static func biologicalSex(_ sex: HKBiologicalSex) -> JSONValue {
    switch sex {
    case .female: "female"
    case .male: "male"
    case .other: "other"
    default: "notSet"
    }
  }

  public static func bloodType(_ type: HKBloodType) -> JSONValue {
    switch type {
    case .aPositive: "aPositive"
    case .aNegative: "aNegative"
    case .bPositive: "bPositive"
    case .bNegative: "bNegative"
    case .abPositive: "abPositive"
    case .abNegative: "abNegative"
    case .oPositive: "oPositive"
    case .oNegative: "oNegative"
    default: "notSet"
    }
  }

  public static func skinType(_ type: HKFitzpatrickSkinType) -> JSONValue {
    switch type {
    case .I: "I"
    case .II: "II"
    case .III: "III"
    case .IV: "IV"
    case .V: "V"
    case .VI: "VI"
    default: "notSet"
    }
  }

  public static func wheelchairUse(_ use: HKWheelchairUse) -> JSONValue {
    switch use {
    case .yes: "yes"
    case .no: "no"
    default: "notSet"
    }
  }

  public static func activityMoveMode(_ mode: HKActivityMoveMode) -> JSONValue {
    mode == .appleMoveTime ? "appleMoveTime" : "activeEnergy"
  }

  // MARK: - Helpers

  /// A day in any calendar as a Gregorian `YYYY-MM-DD`.
  static func gregorianDay(_ day: DateComponents, calendar: Calendar) -> String? {
    var components = day
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    guard day.year != nil, day.month != nil, day.day != nil,
      let date = calendar.date(from: components)
    else { return nil }
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    let parts = gregorian.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
    let pad = { (value: Int, width: Int) in
      String(repeating: "0", count: max(0, width - String(value).count)) + String(value)
    }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(date, 2))"
  }

  /// HealthKit's UUID, lowercased, as the server keys samples.
  static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

  /// The catalog's unit for a quantity type, which the server and the Mac assume.
  static func unit(for type: HKQuantityType) throws -> HKUnit {
    guard let unit = HealthCatalog.type(id: type.identifier)?.unit else {
      throw UnsupportedSample(type: type.identifier)
    }
    return HKUnit(from: unit)
  }

  /// Times, source, device and metadata, shared by samples and correlations. The device's
  /// properties and the metadata's keys are only those lil health keeps (851-4152,
  /// `HealthCatalog.keptDeviceProperties` and `keptMetadataKeys`).
  static func provenance(of sample: HKSample) -> [String: JSONValue] {
    let revision = sample.sourceRevision
    let os = revision.operatingSystemVersion
    let device = sample.device.map { device -> JSONValue in
      // Every property, then only those kept: not `localIdentifier` or `udiDeviceIdentifier`,
      // which identify one device.
      .object(
        [
          "name": device.name, "manufacturer": device.manufacturer, "model": device.model,
          "hardwareVersion": device.hardwareVersion, "firmwareVersion": device.firmwareVersion,
          "softwareVersion": device.softwareVersion, "localIdentifier": device.localIdentifier,
          "udiDeviceIdentifier": device.udiDeviceIdentifier,
        ]
        .filter { HealthCatalog.keptDeviceProperties.contains($0.key) }
        .compactMapValues { $0.map(JSONValue.string) })
    }
    return [
      "startDate": .number(milliseconds(sample.startDate)),
      "endDate": .number(milliseconds(sample.endDate)),
      "sourceName": .string(revision.source.name),
      "sourceBundleId": .string(revision.source.bundleIdentifier),
      "sourceRevision": .object(
        [
          "version": JSONValue(revision.version),
          "productType": JSONValue(revision.productType),
          "operatingSystemVersion": .string(
            "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ]),
      "device": device ?? .null,
      "metadata": metadata(sample.metadata) {
        (sample as? HKQuantitySample).flatMap { try? unit(for: $0.quantityType) }
      }.map(JSONValue.object) ?? .null,
    ]
  }

  /// An object's metadata as it goes up: only the keys lil health keeps
  /// (`HealthCatalog.keptMetadata`, 851-4152), as JSON, or nil if it has none of them.
  /// `sampleUnit` gives the unit of the quantity sample it's on, if it's on one, asked only for a
  /// key in its sample's unit (`HKMetadataKeySessionEstimate`).
  static func metadata(
    _ metadata: [String: Any]?, sampleUnit: () -> HKUnit? = { nil }
  ) -> [String: JSONValue]? {
    guard let kept = metadata.flatMap(HealthCatalog.keptMetadata) else { return nil }
    var json: [String: JSONValue] = [:]
    for (key, value) in kept {
      json[key] = self.json(value) { quantity in
        quantityUnit(of: quantity, at: key, sampleUnit: sampleUnit)
      }
    }
    return json
  }

  /// The unit a quantity at `key` goes up in (`HealthCatalog.metadataQuantityUnits`), or nil for a
  /// key that has none.
  static func quantityUnit(
    of quantity: HKQuantity, at key: String, sampleUnit: () -> HKUnit?
  ) -> HKUnit? {
    switch HealthCatalog.metadataQuantityUnits[key] {
    case .unit(let unit): return metadataUnits[unit]
    case .recorded(let units):
      // The description's unit, if it's one of these: `HKQuantity` says its unit nowhere else.
      // Only a unit of the list is parsed, since `HKUnit(from:)` raises on one it can't read.
      let recorded = quantity.description.split(separator: " ").last.map(String.init)
      return metadataUnits[recorded.flatMap { units.contains($0) ? $0 : nil } ?? units[0]]
    case .sample: return sampleUnit()
    case nil: return nil
    }
  }

  /// Each unit `HealthCatalog.metadataQuantityUnits` names, parsed once.
  static let metadataUnits: [String: HKUnit] = Dictionary(
    HealthCatalog.metadataQuantityUnits.values.flatMap { unit -> [String] in
      switch unit {
      case .unit(let unit): [unit]
      case .recorded(let units): units
      case .sample: []
      }
    }
    .map { ($0, HKUnit(from: $0)) },
    uniquingKeysWith: { first, _ in first })

  /// Unix milliseconds, rounded to the nearest. Never change how: the server finds a sample by
  /// its type, start date and UUID (`docs/sync/protocol.md`), so a sample uploaded again with its
  /// start rounded differently would be stored twice.
  static func milliseconds(_ date: Date) -> Double {
    (date.timeIntervalSince1970 * 1000).rounded()
  }

  /// A metadata value as JSON (851-4150). A quantity is `{ "value": 84.6, "unit": "m" }` in the
  /// unit `unit` gives, its key's (`HealthCatalog.metadataQuantityUnits`), to 12 significant
  /// digits (`HealthCatalog.significant`), so it's whole without a conversion's noise, as
  /// HealthKit holds it: a
  /// percent (`%`) is a fraction, 0.72 for 72%. A quantity under a key without a unit, or in a unit
  /// it can't be converted to, is its description (`"120 count/min"`, 6 significant digits), as
  /// every quantity was before: HealthKit doesn't say an arbitrary quantity's unit. A date is
  /// `{ "date": "2026-10-12T00:00:00.000Z" }`, ISO 8601 in UTC to the millisecond, rather than
  /// Unix milliseconds that look like any other number, unless it's outside the years 1 to 9999,
  /// which ISO 8601's four-digit years don't hold: that stays milliseconds, as before. Numbers
  /// that aren't finite become null.
  static func json(_ value: Any, unit: (HKQuantity) -> HKUnit? = { _ in nil }) -> JSONValue {
    switch value {
    case let string as String: .string(string)
    case let date as Date:
      isoDate(date).map { .object(["date": .string($0)]) } ?? .number(milliseconds(date))
    case let quantity as HKQuantity:
      if let unit = unit(quantity), quantity.is(compatibleWith: unit) {
        .object([
          "value": json(
            NSNumber(value: HealthCatalog.significant(quantity.doubleValue(for: unit)))),
          "unit": .string(unit.unitString),
        ])
      } else {
        .string(quantity.description)
      }
    case let number as NSNumber:
      CFGetTypeID(number) == CFBooleanGetTypeID()
        ? .bool(number.boolValue)
        : number.doubleValue.isFinite ? .number(number.doubleValue) : .null
    case let array as [Any]: .array(array.map { json($0) })
    case let dictionary as [String: Any]: .object(dictionary.mapValues { json($0) })
    default: .string(String(describing: value))
    }
  }

  /// A date in ISO 8601, in UTC, to the millisecond it goes up as (`milliseconds`), or nil
  /// outside the years 1 to 9999. Written from that whole number by the proleptic Gregorian
  /// calendar, the arithmetic the readers use (`HealthMetadataValues.isoMilliseconds`, and the
  /// server's), not by Foundation, whose ISO 8601 format turns Julian before 1582 (year 1's
  /// first day came out `0001-01-03`) and cuts fractional seconds off rather than round them.
  static func isoDate(_ date: Date) -> String? {
    let rounded = milliseconds(date)
    // 0001-01-01T00:00:00.000Z to 9999-12-31T23:59:59.999Z; not finite is outside too.
    guard (-62_135_596_800_000...253_402_300_799_999).contains(rounded) else { return nil }
    let milliseconds = Int(rounded)
    // Whole days rounded down, so a time before 1970 counts up from its day's start too.
    let days =
      milliseconds >= 0 ? milliseconds / 86_400_000 : (milliseconds - 86_399_999) / 86_400_000
    let time = milliseconds - days * 86_400_000
    // Howard Hinnant's `civil_from_days`.
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, day, time / 3_600_000,
      time / 60000 % 60, time / 1000 % 60, time % 1000)
  }

}
