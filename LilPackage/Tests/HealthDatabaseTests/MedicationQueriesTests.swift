import Foundation
import HealthDatabase
import SQLiteData
import Testing

// Synthetic data only (AGENTS.md): made-up medications and doses.

private func calendar(_ timeZone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZone)!
  return calendar
}

/// October `day`, 2025, at `hour` in `calendar`.
private func date(_ day: Int, _ hour: Int, minute: Int = 0, in calendar: Calendar) -> Date {
  calendar.date(
    from: DateComponents(year: 2025, month: 10, day: day, hour: hour, minute: minute))!
}

private func medication(
  _ id: String, _ name: String, nickname: String? = nil, archived: Bool = false
) -> HealthMedication {
  HealthMedication(
    id: id, name: name, nickname: nickname, generalForm: "tablet", isArchived: archived,
    hasSchedule: true)
}

/// A scheduled dose due at `due`, logged `late` seconds after it.
private func scheduled(
  _ id: String, due: Date, status: MedicationDoseStatus, late: TimeInterval = 0,
  medication: String = "m1"
) -> HealthMedicationDose {
  let logged = due.addingTimeInterval(late)
  return HealthMedicationDose(
    id: id, startDate: logged.unixMilliseconds, endDate: logged.unixMilliseconds,
    medication: medication, logStatus: status.rawValue, scheduleType: 2,
    scheduledDate: due.unixMilliseconds, scheduledDoseQuantity: 1,
    doseQuantity: status == .taken ? 1 : nil, unit: "count", sourceName: "Test",
    sourceBundleID: "com.example")
}

/// A dose taken as needed at `at`.
private func asNeeded(
  _ id: String, at: Date, status: MedicationDoseStatus = .taken, medication: String = "m1"
) -> HealthMedicationDose {
  HealthMedicationDose(
    id: id, startDate: at.unixMilliseconds, endDate: at.unixMilliseconds, medication: medication,
    logStatus: status.rawValue, scheduleType: 1, doseQuantity: 1, unit: "count",
    sourceName: "Test", sourceBundleID: "com.example")
}

@Suite
struct MedicationQueriesTests {
  @Test
  func currentMedicationsComeFirstThenArchivedOnesByTheNameTheyShow() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthMedication.insert {
        medication("m1", "Synthetic Tablet C")
        medication("m2", "Synthetic Tablet B", archived: true)
        medication("m3", "Synthetic Tablet Z", nickname: "A Nickname")
        medication("m4", "Synthetic Tablet A", archived: true)
        medication("m5", "synthetic tablet b", nickname: "  ")
      }
      .execute(db)
    }
    let medications = try database.read { db in try HealthDatabase.medications(db) }
    #expect(medications.map(\.id) == ["m3", "m5", "m1", "m4", "m2"])
    // A blank nickname isn't a name.
    #expect(medications.map(\.displayName).prefix(2) == ["A Nickname", "synthetic tablet b"])
  }

  @Test
  func adherenceCountsScheduledDosesTakenInTheLastDays() {
    let calendar = calendar("UTC")
    let now = date(14, 12, in: calendar)
    let doses = [
      // Today and the six days before: Oct 8 through 14.
      scheduled("a", due: date(14, 8, in: calendar), status: .taken, late: 600),
      scheduled("b", due: date(13, 8, in: calendar), status: .skipped),
      scheduled("c", due: date(12, 8, in: calendar), status: .notInteracted),
      scheduled("d", due: date(8, 8, in: calendar), status: .taken),
      // Before the 7 days, but in the 30.
      scheduled("e", due: date(7, 23, in: calendar), status: .taken),
      scheduled("f", due: date(1, 8, in: calendar), status: .snoozed),
      // Before the 30 days (September 15 is the first).
      scheduled(
        "g", due: date(14, 8, in: calendar).addingTimeInterval(-31 * 86_400), status: .taken),
      asNeeded("h", at: date(14, 9, in: calendar)),
      asNeeded("i", at: date(10, 9, in: calendar), status: .skipped),
    ]
    #expect(
      MedicationAdherence(days: 7, doses: doses, now: now, calendar: calendar)
        == MedicationAdherence(days: 7, scheduled: 4, taken: 2, takenAsNeeded: 1))
    #expect(
      MedicationAdherence(days: 30, doses: doses, now: now, calendar: calendar)
        == MedicationAdherence(days: 30, scheduled: 6, taken: 3, takenAsNeeded: 1))
    #expect(MedicationAdherence(days: 7, scheduled: 4, taken: 2).fraction == 0.5)
    #expect(MedicationAdherence(days: 7, scheduled: 0, taken: 0).fraction == nil)
  }

  @Test
  func aScheduledDoseCountsOnceAsItsLatestLog() {
    let calendar = calendar("UTC")
    let now = date(14, 12, in: calendar)
    let due = date(14, 8, in: calendar)
    let doses = [
      scheduled("a", due: due, status: .snoozed, late: 60),
      scheduled("b", due: due, status: .taken, late: 900),
      // Taken, then undone.
      scheduled("c", due: date(13, 8, in: calendar), status: .taken, late: 60),
      scheduled("d", due: date(13, 8, in: calendar), status: .notLogged, late: 120),
    ]
    #expect(
      MedicationAdherence(days: 7, doses: doses, now: now, calendar: calendar)
        == MedicationAdherence(days: 7, scheduled: 2, taken: 1))
  }

  @Test
  func adherenceWindowsFollowTheCalendarsTimeZone() {
    // 23:30 on October 7 in Los Angeles is 06:30 on October 8 in UTC.
    let losAngeles = calendar("America/Los_Angeles")
    let due = date(7, 23, minute: 30, in: losAngeles)
    let doses = [scheduled("a", due: due, status: .taken)]
    #expect(
      MedicationAdherence(
        days: 7, doses: doses, now: date(14, 12, in: losAngeles), calendar: losAngeles
      ).scheduled == 0)
    let utc = calendar("UTC")
    #expect(
      MedicationAdherence(days: 7, doses: doses, now: date(14, 12, in: utc), calendar: utc)
        .scheduled == 1)
  }

  @Test
  func dosesGroupByTheDayTheyWereDueNewestFirst() {
    let tokyo = calendar("Asia/Tokyo")
    let doses = [
      scheduled("morning", due: date(13, 8, in: tokyo), status: .taken),
      // Due late on the 13th, taken after midnight: still the 13th's.
      scheduled("late", due: date(13, 23, in: tokyo), status: .taken, late: 7_200),
      asNeeded("noon", at: date(14, 12, in: tokyo)),
      scheduled("skipped", due: date(11, 8, in: tokyo), status: .skipped),
    ]
    let days = MedicationDoseDay.days(doses, calendar: tokyo)
    #expect(
      days.map(\.day) == [date(14, 0, in: tokyo), date(13, 0, in: tokyo), date(11, 0, in: tokyo)])
    #expect(days.map { $0.doses.map(\.id) } == [["noon"], ["late", "morning"], ["skipped"]])
    // In UTC, 08:00 in Tokyo is the day before.
    let utc = calendar("UTC")
    #expect(
      MedicationDoseDay.days(doses, calendar: utc).map(\.day) == [
        date(14, 0, in: utc), date(13, 0, in: utc), date(12, 0, in: utc), date(10, 0, in: utc),
      ])
  }

  @Test
  func detailReadsTheMedicationsOwnDosesUpToTheLimit() throws {
    let calendar = calendar("UTC")
    let now = date(14, 12, in: calendar)
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthMedication.insert {
        medication("m1", "Synthetic Tablet A")
        medication("m2", "Synthetic Tablet B")
      }
      .execute(db)
      try HealthMedicationDose.insert {
        scheduled("a", due: date(14, 8, in: calendar), status: .taken)
        scheduled("b", due: date(13, 8, in: calendar), status: .skipped)
        scheduled("c", due: date(12, 8, in: calendar), status: .taken)
        scheduled("other", due: date(14, 8, in: calendar), status: .taken, medication: "m2")
      }
      .execute(db)
    }
    let detail = try database.read { db in
      try HealthDatabase.medicationDetail(id: "m1", now: now, calendar: calendar, limit: 2, db)
    }
    #expect(detail?.medication.name == "Synthetic Tablet A")
    #expect(detail?.days.map { $0.doses.map(\.id) } == [["a"], ["b"]])
    #expect(detail?.isLimited == true)
    // Adherence counts every dose in the window, not only the log's.
    #expect(
      detail?.adherence == [
        MedicationAdherence(days: 7, scheduled: 3, taken: 2),
        MedicationAdherence(days: 30, scheduled: 3, taken: 2),
      ])
    let all = try database.read { db in
      try HealthDatabase.medicationDetail(id: "m1", now: now, calendar: calendar, limit: 10, db)
    }
    #expect(all?.isLimited == false)
    let missing = try database.read { db in
      try HealthDatabase.medicationDetail(id: "gone", now: now, calendar: calendar, limit: 10, db)
    }
    #expect(missing == nil)
  }

  @Test
  func statusesAndFormsReadFromHealthKitsRawValues() {
    #expect(MedicationDoseStatus(rawValue: 4) == .taken)
    #expect(MedicationDoseStatus(rawValue: 5) == .skipped)
    #expect(MedicationDoseStatus(rawValue: 1)?.name == "Not Logged")
    #expect(MedicationDoseStatus(rawValue: 7) == nil)
    #expect(medication("m", "A").formName == "Tablet")
    var unknown = medication("m", "A")
    unknown.generalForm = "unknown"
    #expect(unknown.formName == nil)
  }
}
