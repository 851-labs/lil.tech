public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// Every shared medication: current ones first, then archived ones, each by the name it shows.
  public static func medications(_ db: Database) throws -> [HealthMedication] {
    try HealthMedication.fetchAll(db).sorted { a, b in
      if a.isArchived != b.isArchived { return !a.isArchived }
      let order = a.displayName.localizedStandardCompare(b.displayName)
      return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
  }

  /// A medication, its adherence over the last 7 and 30 days, and its latest `limit` doses by
  /// day, as of `now` in `calendar`. `nil` once it's no longer shared.
  public static func medicationDetail(
    id: String, now: Date, calendar: Calendar, limit: Int, _ db: Database
  ) throws -> MedicationDetail? {
    guard let medication = try HealthMedication.find(id).fetchOne(db) else { return nil }
    // One more than shown, to know whether there are more.
    let latest =
      try HealthMedicationDose
      .where { $0.medication.eq(id) }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit + 1)
      .fetchAll(db)
    let isLimited = latest.count > limit
    var days = MedicationDoseDay.days(Array(latest.prefix(limit)), calendar: calendar)
    // Cut by when doses were logged, the oldest day shown may be missing some: it's left out.
    if isLimited, days.count > 1 { days.removeLast() }
    // A dose counts on its scheduled day, however long before or after it was logged.
    let windowStart = MedicationAdherence.start(days: 30, now: now, calendar: calendar)
      .unixMilliseconds
    let recent =
      try HealthMedicationDose
      .where { $0.medication.eq(id) && ($0.scheduledDate ?? $0.startDate) >= windowStart }
      .fetchAll(db)
    return MedicationDetail(
      medication: medication,
      adherence: [7, 30].map {
        MedicationAdherence(days: $0, doses: recent, now: now, calendar: calendar)
      },
      days: days, isLimited: isLimited)
  }
}

/// What a medication's page shows.
public struct MedicationDetail: Equatable, Sendable {
  public var medication: HealthMedication
  /// Over the last 7 days, then the last 30.
  public var adherence: [MedicationAdherence]
  /// The dose log, newest day first.
  public var days: [MedicationDoseDay]
  /// Whether the log holds only the latest doses, not all of them.
  public var isLimited: Bool

  public init(
    medication: HealthMedication, adherence: [MedicationAdherence], days: [MedicationDoseDay],
    isLimited: Bool = false
  ) {
    self.medication = medication
    self.adherence = adherence
    self.days = days
    self.isLimited = isLimited
  }
}

/// How many of a medication's scheduled doses were taken over the last `days` days (today and the
/// days before it), and how many doses were taken as needed.
///
/// Each scheduled dose (a medication and a scheduled time) counts once. Health normally keeps one
/// event for it, but should it have several (snoozed, then taken), the latest logged one says
/// what happened.
public struct MedicationAdherence: Equatable, Sendable {
  public var days: Int
  /// Scheduled doses in the window, whatever happened to them.
  public var scheduled: Int
  /// Of those, the ones taken.
  public var taken: Int
  /// Doses taken as needed, outside any schedule.
  public var takenAsNeeded: Int

  public init(days: Int, scheduled: Int, taken: Int, takenAsNeeded: Int = 0) {
    self.days = days
    self.scheduled = scheduled
    self.taken = taken
    self.takenAsNeeded = takenAsNeeded
  }

  /// Counts `doses` (of one medication) whose day, `MedicationDoseDay.date(of:)`, falls in the
  /// last `days` days as of `now` in `calendar`.
  public init(days: Int, doses: [HealthMedicationDose], now: Date, calendar: Calendar) {
    let start = Self.start(days: days, now: now, calendar: calendar).unixMilliseconds
    let end =
      (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now)
      .unixMilliseconds
    let inWindow = doses.filter { (start..<end).contains($0.scheduledDate ?? $0.startDate) }
    var slots: [Int: HealthMedicationDose] = [:]
    var takenAsNeeded = 0
    for dose in inWindow {
      guard dose.schedule == .scheduled, let scheduled = dose.scheduledDate else {
        if dose.status == .taken { takenAsNeeded += 1 }
        continue
      }
      if let other = slots[scheduled],
        (other.startDate, other.id) > (dose.startDate, dose.id)
      {
        continue
      }
      slots[scheduled] = dose
    }
    self.init(
      days: days, scheduled: slots.count,
      taken: slots.values.count { $0.status == .taken }, takenAsNeeded: takenAsNeeded)
  }

  /// The share of scheduled doses taken, from 0 to 1, or `nil` without any.
  public var fraction: Double? {
    scheduled == 0 ? nil : Double(taken) / Double(scheduled)
  }

  /// The start of the window: midnight `days - 1` days before today.
  public static func start(days: Int, now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
  }
}

/// A day of a medication's dose log, its doses newest first.
public struct MedicationDoseDay: Equatable, Sendable, Identifiable {
  /// Midnight, in the calendar the log was grouped in.
  public var day: Date
  public var doses: [HealthMedicationDose]

  public var id: Date { day }

  public init(day: Date, doses: [HealthMedicationDose]) {
    self.day = day
    self.doses = doses
  }

  /// When a dose belongs: its scheduled time, so a dose taken after midnight stays with the day it
  /// was due, or when it was logged for one taken as needed.
  public static func date(of dose: HealthMedicationDose) -> Date {
    Date(unixMilliseconds: dose.scheduledDate ?? dose.startDate)
  }

  /// `doses` by their day in `calendar`, newest day first, and newest first within a day.
  public static func days(_ doses: [HealthMedicationDose], calendar: Calendar) -> [Self] {
    Dictionary(grouping: doses) { calendar.startOfDay(for: date(of: $0)) }
      .map { day, doses in
        MedicationDoseDay(
          day: day,
          doses: doses.sorted {
            (date(of: $0), $0.startDate, $0.id) > (date(of: $1), $1.startDate, $1.id)
          })
      }
      .sorted { $0.day > $1.day }
  }
}

/// What happened to a dose (`HKMedicationDoseEvent.LogStatus`, by raw value).
public enum MedicationDoseStatus: Int, Sendable {
  /// A scheduled dose whose reminder went unanswered.
  case notInteracted = 1
  /// A scheduled dose whose reminder couldn't be sent.
  case notificationNotSent = 2
  case snoozed = 3
  case taken = 4
  case skipped = 5
  /// A status the person undid.
  case notLogged = 6

  public var name: String {
    switch self {
    case .notInteracted, .notLogged: "Not Logged"
    case .notificationNotSent: "Reminder Not Sent"
    case .snoozed: "Snoozed"
    case .taken: "Taken"
    case .skipped: "Skipped"
    }
  }
}

/// Whether a dose was scheduled (`HKMedicationDoseEvent.ScheduleType`, by raw value).
public enum MedicationDoseSchedule: Int, Sendable {
  case asNeeded = 1
  case scheduled = 2
}

extension HealthMedicationDose {
  /// What happened to it, or `nil` for a status from a newer iOS.
  public var status: MedicationDoseStatus? { MedicationDoseStatus(rawValue: logStatus) }

  /// Scheduled or as needed, or `nil` for a schedule type from a newer iOS.
  public var schedule: MedicationDoseSchedule? { MedicationDoseSchedule(rawValue: scheduleType) }

  /// When it was logged (taken, skipped…).
  public var logged: Date { Date(unixMilliseconds: startDate) }

  /// When it was due, if it was scheduled.
  public var scheduled: Date? { scheduledDate.map(Date.init(unixMilliseconds:)) }
}

extension HealthMedication {
  /// The name the person gave it, or Health's.
  public var displayName: String {
    guard let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return name
    }
    return nickname
  }

  /// Its form, "Tablet" or "Capsule", or `nil` when Health doesn't know it or it's from a newer
  /// iOS.
  public var formName: String? {
    switch generalForm {
    case "capsule": "Capsule"
    case "cream": "Cream"
    case "device": "Device"
    case "drops": "Drops"
    case "foam": "Foam"
    case "gel": "Gel"
    case "inhaler": "Inhaler"
    case "injection": "Injection"
    case "liquid": "Liquid"
    case "lotion": "Lotion"
    case "ointment": "Ointment"
    case "patch": "Patch"
    case "powder": "Powder"
    case "spray": "Spray"
    case "suppository": "Suppository"
    case "tablet": "Tablet"
    case "topical": "Topical"
    default: nil
    }
  }
}
