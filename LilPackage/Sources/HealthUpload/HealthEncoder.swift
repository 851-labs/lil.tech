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
    row["correlationId"] = JSONValue(correlation.map(id))
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

  /// A deleted sample or correlation (`HKDeletedObject`).
  public static func deleted(_ uuid: UUID, correlation: Bool = false) -> HealthMutation {
    .delete(correlation ? correlationEntity : sampleEntity, id: id(uuid))
  }

  /// One day's Activity rings, keyed by its day: `summary.dateComponents(for:)` in the iPhone's
  /// calendar.
  public static func activitySummary(
    _ summary: HKActivitySummary, day: DateComponents
  ) -> HealthMutation? {
    guard let year = day.year, let month = day.month, let date = day.day else { return nil }
    let id = String(format: "%04d-%02d-%02d", year, month, date)
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
        "activityMoveMode": .string(moveTime ? "appleMoveTime" : "activeEnergy"),
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

  /// HealthKit's UUID, lowercased, as the server keys samples.
  static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

  /// The catalog's unit for a quantity type, which the server and the Mac assume.
  static func unit(for type: HKQuantityType) throws -> HKUnit {
    guard let unit = HealthCatalog.type(id: type.identifier)?.unit else {
      throw UnsupportedSample(type: type.identifier)
    }
    return HKUnit(from: unit)
  }

  /// Times, source, device and metadata, shared by samples and correlations.
  static func provenance(of sample: HKSample) -> [String: JSONValue] {
    let revision = sample.sourceRevision
    let os = revision.operatingSystemVersion
    let device = sample.device.map { device -> JSONValue in
      .object(
        [
          "name": device.name, "manufacturer": device.manufacturer, "model": device.model,
          "hardwareVersion": device.hardwareVersion, "firmwareVersion": device.firmwareVersion,
          "softwareVersion": device.softwareVersion, "localIdentifier": device.localIdentifier,
          "udiDeviceIdentifier": device.udiDeviceIdentifier,
        ]
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
      "metadata": sample.metadata.map { .object($0.mapValues(json)) } ?? .null,
    ]
  }

  static func milliseconds(_ date: Date) -> Double {
    (date.timeIntervalSince1970 * 1000).rounded()
  }

  /// A metadata value as JSON: dates as Unix milliseconds, quantities as their description
  /// (e.g. `"120 count/min"`).
  static func json(_ value: Any) -> JSONValue {
    switch value {
    case let string as String: .string(string)
    case let date as Date: .number(milliseconds(date))
    case let quantity as HKQuantity: .string(quantity.description)
    case let number as NSNumber:
      CFGetTypeID(number) == CFBooleanGetTypeID()
        ? .bool(number.boolValue)
        : .number(number.doubleValue)
    case let array as [Any]: .array(array.map(json))
    case let dictionary as [String: Any]: .object(dictionary.mapValues(json))
    default: .string(String(describing: value))
    }
  }
}
