import CryptoKit
public import Foundation
public import HealthKit

/// A medication the person shares with the app, read out of `HKUserAnnotatedMedication`
/// (`init(_:)`) so the encoding can be tested without HealthKit, which doesn't let apps create
/// one.
public struct MedicationRecord: Equatable, Sendable {
  /// Its concept's ID (`HealthEncoder.conceptID(_:)`), which its dose events refer to.
  public var id: String
  /// The concept's name, as Health shows it (`displayText`).
  public var name: String
  /// The name the person gave it, if any.
  public var nickname: String?
  /// `HKMedicationGeneralForm`'s raw value, e.g. `"tablet"`.
  public var generalForm: String
  public var isArchived: Bool
  public var hasSchedule: Bool
  /// Codes for it in clinical systems, e.g. RxNorm's.
  public var codings: [Coding]

  public struct Coding: Equatable, Sendable {
    public var system: String
    public var version: String?
    public var code: String

    public init(system: String, version: String?, code: String) {
      self.system = system
      self.version = version
      self.code = code
    }
  }

  public init(
    id: String, name: String, nickname: String?, generalForm: String, isArchived: Bool,
    hasSchedule: Bool, codings: [Coding]
  ) {
    self.id = id
    self.name = name
    self.nickname = nickname
    self.generalForm = generalForm
    self.isArchived = isArchived
    self.hasSchedule = hasSchedule
    self.codings = codings
  }
}

extension MedicationRecord {
  public init(_ medication: HKUserAnnotatedMedication) {
    let concept = medication.medication
    self.init(
      id: HealthEncoder.conceptID(concept.identifier), name: concept.displayText,
      nickname: medication.nickname, generalForm: concept.generalForm.rawValue,
      isArchived: medication.isArchived, hasSchedule: medication.hasSchedule,
      codings: concept.relatedCodings.map {
        Coding(system: $0.system, version: $0.version, code: $0.code)
      })
  }
}

/// A logged (or skipped, or missed) dose, read out of `HKMedicationDoseEvent` (`init(_:)`) so the
/// encoding can be tested without HealthKit, which doesn't let apps create one.
public struct MedicationDoseRecord: Equatable, Sendable {
  public var id: UUID
  /// Its medication's concept ID (`HealthEncoder.conceptID(_:)`).
  public var medication: String
  /// `HKMedicationDoseEvent.LogStatus`'s raw value, e.g. 4 for taken.
  public var logStatus: Int
  /// `HKMedicationDoseEvent.ScheduleType`'s raw value: 1 as needed, 2 scheduled.
  public var scheduleType: Int
  public var scheduledDate: Date?
  public var scheduledDoseQuantity: Double?
  public var doseQuantity: Double?
  /// The quantities' unit, as an `HKUnit` string.
  public var unit: String
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]

  public init(
    id: UUID, medication: String, logStatus: Int, scheduleType: Int, scheduledDate: Date?,
    scheduledDoseQuantity: Double?, doseQuantity: Double?, unit: String,
    provenance: [String: JSONValue]
  ) {
    self.id = id
    self.medication = medication
    self.logStatus = logStatus
    self.scheduleType = scheduleType
    self.scheduledDate = scheduledDate
    self.scheduledDoseQuantity = scheduledDoseQuantity
    self.doseQuantity = doseQuantity
    self.unit = unit
    self.provenance = provenance
  }
}

extension MedicationDoseRecord {
  public init(_ dose: HKMedicationDoseEvent) {
    self.init(
      id: dose.uuid, medication: HealthEncoder.conceptID(dose.medicationConceptIdentifier),
      logStatus: dose.logStatus.rawValue, scheduleType: dose.scheduleType.rawValue,
      scheduledDate: dose.scheduledDate, scheduledDoseQuantity: dose.scheduledDoseQuantity,
      doseQuantity: dose.doseQuantity, unit: dose.unit.unitString,
      provenance: HealthEncoder.provenance(of: dose))
  }
}

extension HealthEncoder {
  public static let medicationEntity = "health_medication"
  public static let medicationDoseEntity = "health_medication_dose"

  /// A medication, keyed by its concept's ID (`HealthMedication` on the server). Codings are
  /// sorted, so the same medication always encodes the same.
  public static func medication(_ medication: MedicationRecord) -> HealthMutation {
    let codings = medication.codings.sorted {
      ($0.system, $0.code, $0.version ?? "") < ($1.system, $1.code, $1.version ?? "")
    }
    return .upsert(
      medicationEntity, id: medication.id,
      row: [
        "name": .string(medication.name),
        "nickname": JSONValue(medication.nickname),
        "generalForm": .string(medication.generalForm),
        "isArchived": .bool(medication.isArchived),
        "hasSchedule": .bool(medication.hasSchedule),
        "codings": .array(
          codings.map {
            .object([
              "system": .string($0.system), "version": JSONValue($0.version),
              "code": .string($0.code),
            ])
          }),
      ])
  }

  /// Every medication shared, one per concept: its doses only say which concept they're of. If
  /// Health has a concept twice, a current one wins over an archived one, then the first by name.
  public static func medications(_ medications: [MedicationRecord]) -> [HealthMutation] {
    let ordered = medications.sorted {
      ($0.isArchived ? 1 : 0, $0.nickname ?? "", $0.name)
        < ($1.isArchived ? 1 : 0, $1.nickname ?? "", $1.name)
    }
    var seen: Set<String> = []
    return ordered.filter { seen.insert($0.id).inserted }.map(medication)
  }

  /// A dose event (`HealthMedicationDose` on the server).
  public static func medicationDose(_ dose: MedicationDoseRecord) -> HealthMutation {
    var row = dose.provenance
    row["medication"] = .string(dose.medication)
    row["logStatus"] = JSONValue(dose.logStatus)
    row["scheduleType"] = JSONValue(dose.scheduleType)
    row["scheduledDate"] = JSONValue(dose.scheduledDate.map(milliseconds))
    row["scheduledDoseQuantity"] = JSONValue(dose.scheduledDoseQuantity)
    row["doseQuantity"] = JSONValue(dose.doseQuantity)
    row["unit"] = .string(dose.unit)
    return .upsert(medicationDoseEntity, id: id(dose.id), row: row)
  }

  /// A medication concept's ID: the SHA-256, in lowercase hex, of what its identifier archives
  /// (its domain and underlying identifier). `HKHealthConceptIdentifier` has no public value
  /// other than its domain, but it's equal to another exactly when those are, and every device
  /// archives the same concept the same, so medications and their doses match across runs and
  /// iPhones. If a later iOS archived it differently, the medications' IDs would change once:
  /// the old ones are deleted with their doses, and the doses are read again with the new ones.
  public static func conceptID(_ identifier: HKHealthConceptIdentifier) -> String {
    let collector = ArchivedValues()
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.delegate = collector
    archiver.encode(identifier, forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    // Its values, in the order it encodes them; the archive's bytes only if it has none, since
    // they also name the strings' classes, which may differ with how the identifier was made.
    let bytes =
      collector.values.isEmpty
      ? archiver.encodedData : Data(collector.values.joined(separator: "\u{0}").utf8)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// Collects the strings and numbers an object archives, through `NSKeyedArchiver`'s delegate.
  private final class ArchivedValues: NSObject, NSKeyedArchiverDelegate {
    var values: [String] = []

    func archiver(_ archiver: NSKeyedArchiver, willEncode object: Any) -> Any? {
      switch object {
      case let string as String: values.append(string)
      case let number as NSNumber: values.append(number.stringValue)
      default: break
      }
      return object
    }
  }
}
