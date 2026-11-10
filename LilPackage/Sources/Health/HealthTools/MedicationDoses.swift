import Foundation
import HealthDatabase
public import SQLiteData

// The dose log (851-4167): `medication_doses` lists the doses of the shared medications, in the
// words of the app's Medications page (`MedicationsView.swift`), a page at a time. The remote
// server does the same (`Services/api/src/health/tools/Medications.ts`), rule for rule.

extension HealthTools {
  /// The most doses one call returns, and how many it returns by default.
  public static let medicationDosesLimit = 250
  public static let medicationDosesDefaultLimit = 100

  /// The doses of the shared medications (or of `medication`) whose day, when they were due or
  /// else logged, is in the period, newest first, a page at a time, with the period's count.
  public func medicationDoses(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, medication: String? = nil,
    cursor: String? = nil, limit: Int? = nil, _ db: Database
  ) throws -> HealthMedicationDosesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let limit = limit ?? Self.medicationDosesDefaultLimit
    guard (1...Self.medicationDosesLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.medicationDosesLimit).")
    }
    let after = try cursor.map(Self.doseCursor)
    let medications = try HealthDatabase.medications(db)
    let names = Dictionary(
      medications.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    if let medication, names[medication] == nil {
      throw HealthToolError(
        "No medication with ID \(medication). medications lists them, with their IDs.")
    }
    // One more than asked for, to know whether there's another page.
    let (count, doses) = try HealthDatabase.doseLog(
      of: medication.map { [$0] } ?? medications.map(\.id), in: period.interval, after: after,
      limit: limit + 1, db)
    let page = doses.prefix(limit)
    let zones = RecordedZones()
    return HealthMedicationDosesResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      doses: page.map { dose in
        let recorded = zones.time(json: dose.metadata, at: dose.startDate)
        let recordedScheduled = dose.scheduledDate.map { zones.time(json: dose.metadata, at: $0) }
        return HealthMedicationDoseItem(
          medicationId: dose.medication, medication: names[dose.medication] ?? dose.medication,
          status: dose.status?.name ?? "Unknown", schedule: dose.schedule?.name ?? "Unknown",
          time: time.localTime(dose.logged), scheduledTime: dose.scheduled.map(time.localTime),
          recordedTimeZone: recorded.timeZone, recordedTime: recorded.time,
          recordedScheduledTime: recordedScheduled?.time, amount: dose.doseQuantity,
          scheduledAmount: dose.scheduledDoseQuantity, unit: dose.unit, source: dose.sourceName)
      },
      nextCursor: doses.count > limit
        ? page.last.map { Self.doseCursorText(DoseCursor(after: $0)) } : nil)
  }

  /// A page's cursor: its last dose's day, logged time and ID, `<day>_<start>_<id>`.
  static func doseCursorText(_ cursor: DoseCursor) -> String {
    "\(cursor.day)_\(cursor.startDate)_\(cursor.id)"
  }

  /// A cursor's day, logged time and ID, all there (`1_2_` isn't one), as the server reads them.
  private static func doseCursor(_ text: String) throws -> DoseCursor {
    let parts = text.split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count == 3, let day = Self.cursorNumber(parts[0]),
      let start = Self.cursorNumber(parts[1]), !parts[2].isEmpty
    else {
      throw HealthToolError("Invalid cursor: \(text). Pass the previous page's nextCursor.")
    }
    return DoseCursor(day: day, startDate: start, id: String(parts[2]))
  }

  /// A cursor's whole number: digits, after an optional sign, as the server's `[+-]?\d+`.
  private static func cursorNumber(_ text: Substring) -> Int? {
    let digits = text.first == "+" || text.first == "-" ? text.dropFirst() : text
    guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int(text)
  }
}

/// A dose, in the words of the Mac's dose log.
public struct HealthMedicationDoseItem: Codable, Equatable, Sendable {
  public var medicationId: String
  /// The medication's name: the one the person gave it, else Health's.
  public var medication: String
  /// E.g. `Taken`, as `MedicationDoseStatus` names it, or `Unknown` for one a later iOS adds.
  public var status: String
  /// `Scheduled` or `As Needed`, or `Unknown` for one a later iOS adds.
  public var schedule: String
  public var time: String
  public var scheduledTime: String?
  /// The zone it was recorded in, when it's a name the tools take, and its times on that zone's
  /// clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedTime: String? = nil
  public var recordedScheduledTime: String? = nil
  public var amount: Double?
  public var scheduledAmount: Double?
  /// An `HKUnit` string, e.g. `mg`, or `count`.
  public var unit: String
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(medicationId, .medicationId)
    try container.encode(medication, .medication)
    try container.encode(status, .status)
    try container.encode(schedule, .schedule)
    try container.encode(time, .time)
    try container.encode(scheduledTime, .scheduledTime)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedTime, forKey: .recordedTime)
    try container.encodeIfPresent(recordedScheduledTime, forKey: .recordedScheduledTime)
    try container.encode(amount, .amount)
    try container.encode(scheduledAmount, .scheduledAmount)
    try container.encode(unit, .unit)
    try container.encode(source, .source)
  }
}

public struct HealthMedicationDosesResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var doses: [HealthMedicationDoseItem]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(range, .range)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(count, .count)
    try container.encode(doses, .doses)
    try container.encode(nextCursor, .nextCursor)
  }
}
