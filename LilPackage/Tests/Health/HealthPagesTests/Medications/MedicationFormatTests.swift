import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

// Synthetic data only (AGENTS.md).

private let locale = Locale(identifier: "en_US")

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
  utcCalendar().date(
    from: DateComponents(year: 2025, month: month, day: day, hour: hour, minute: minute))!
}

private func dose(
  status: Int, logged: Date, due: Date? = nil, taken: Double? = nil, scheduled: Double? = nil,
  unit: String = "count"
) -> HealthMedicationDose {
  HealthMedicationDose(
    id: "d", startDate: logged.unixMilliseconds, endDate: logged.unixMilliseconds,
    medication: "m", logStatus: status, scheduleType: due == nil ? 1 : 2,
    scheduledDate: due?.unixMilliseconds, scheduledDoseQuantity: scheduled, doseQuantity: taken,
    unit: unit, sourceName: "Test", sourceBundleID: "com.example")
}

struct MedicationFormatTests {
  @Test
  func detailsNameHealthsNameUnderANicknameAndTheForm() {
    let named = HealthMedication(id: "m", name: "Synthetic Tablet A", generalForm: "tablet")
    #expect(MedicationFormat.details(named) == "Tablet")
    var nicknamed = named
    nicknamed.nickname = "Morning"
    #expect(MedicationFormat.details(nicknamed) == "Synthetic Tablet A · Tablet")
    nicknamed.generalForm = "unknown"
    #expect(MedicationFormat.details(nicknamed) == "Synthetic Tablet A")
    var plain = named
    plain.generalForm = "unknown"
    #expect(MedicationFormat.details(plain) == nil)
    #expect(MedicationFormat.schedule(named) == "As Needed")
  }

  @Test
  func adherenceReadsAsAShareOfScheduledDosesOrDosesAsNeeded() {
    let some = MedicationAdherence(days: 7, scheduled: 14, taken: 12, takenAsNeeded: 2)
    #expect(MedicationFormat.adherenceValue(some, locale: locale) == "86%")
    #expect(
      MedicationFormat.adherenceCaption(some) == "12 of 14 scheduled doses taken, plus 2 as needed")
    let one = MedicationAdherence(days: 7, scheduled: 1, taken: 0)
    #expect(MedicationFormat.adherenceValue(one, locale: locale) == "0%")
    #expect(MedicationFormat.adherenceCaption(one) == "0 of 1 scheduled dose taken")
    let asNeeded = MedicationAdherence(days: 7, scheduled: 0, taken: 0, takenAsNeeded: 3)
    #expect(MedicationFormat.adherenceValue(asNeeded, locale: locale) == "3")
    #expect(MedicationFormat.adherenceCaption(asNeeded) == "Doses taken as needed")
    let none = MedicationAdherence(days: 30, scheduled: 0, taken: 0)
    #expect(MedicationFormat.adherenceValue(none, locale: locale) == "–")
    #expect(MedicationFormat.adherenceCaption(none) == "No doses logged")
  }

  @Test
  func daysAreTodayYesterdayOrTheirDate() {
    let calendar = utcCalendar()
    let now = date(10, 14, 12)
    func day(_ date: Date) -> String {
      MedicationFormat.day(date, now: now, calendar: calendar, locale: locale)
    }
    #expect(day(date(10, 14, 0)) == "Today")
    #expect(day(date(10, 13, 0)) == "Yesterday")
    #expect(day(date(10, 6, 0)) == "Monday, October 6")
    #expect(
      MedicationFormat.day(
        date(12, 31, 0).addingTimeInterval(-365 * 86_400), now: now, calendar: calendar,
        locale: locale) == "Tuesday, December 31, 2024")
  }

  @Test
  func timesSayWhenADoseWasLoggedAndDue() {
    let calendar = utcCalendar()
    func times(_ dose: HealthMedicationDose) -> String {
      MedicationFormat.times(dose, calendar: calendar, locale: locale)
    }
    let due = date(10, 14, 8)
    #expect(
      times(dose(status: 4, logged: date(10, 14, 8, 12), due: due))
        == "8:12\u{202F}AM · Scheduled for 8:00\u{202F}AM")
    #expect(times(dose(status: 5, logged: due, due: due)) == "8:00\u{202F}AM · Scheduled")
    #expect(
      times(dose(status: 1, logged: date(10, 14, 9), due: due)) == "Scheduled for 8:00\u{202F}AM")
    #expect(times(dose(status: 4, logged: date(10, 14, 21, 5))) == "9:05\u{202F}PM")
  }

  @Test
  func quantitiesNameTheFormForCounts() {
    let tablet = HealthMedication(id: "m", name: "Synthetic Tablet A", generalForm: "tablet")
    let logged = date(10, 14, 8)
    func quantity(_ dose: HealthMedicationDose, _ medication: HealthMedication = tablet)
      -> String?
    {
      MedicationFormat.quantity(dose, medication: medication, locale: locale)
    }
    #expect(quantity(dose(status: 4, logged: logged, taken: 1, scheduled: 2)) == "1 tablet")
    #expect(quantity(dose(status: 4, logged: logged, taken: 1.5)) == "1.5 tablets")
    // Singular as shown, after rounding.
    #expect(quantity(dose(status: 4, logged: logged, taken: 1.0001)) == "1 tablet")
    // A dose that wasn't taken shows what was due.
    #expect(quantity(dose(status: 5, logged: logged, due: logged, scheduled: 2)) == "2 tablets")
    #expect(quantity(dose(status: 4, logged: logged, taken: 5, unit: "mL")) == "5 mL")
    #expect(quantity(dose(status: 1, logged: logged)) == nil)
    let drops = HealthMedication(id: "m", name: "Synthetic Drops", generalForm: "drops")
    #expect(quantity(dose(status: 4, logged: logged, taken: 1), drops) == "1 drop")
    let other = HealthMedication(id: "m", name: "Synthetic Gel", generalForm: "gel")
    #expect(quantity(dose(status: 4, logged: logged, taken: 2), other) == "2 doses")
  }

  @Test
  func daysShowWholeDaysUntilTheyHoldThePage() {
    let logged = date(10, 14, 8)
    let days = [3, 2, 3].enumerated().map { index, count in
      MedicationDoseDay(
        day: date(10, 14 - index, 0),
        doses: Array(repeating: dose(status: 4, logged: logged), count: count))
    }
    #expect(MedicationFormat.days(days, upTo: 1).map(\.doses.count) == [3])
    #expect(MedicationFormat.days(days, upTo: 3).map(\.doses.count) == [3])
    // A day isn't cut: four doses take the second day whole.
    #expect(MedicationFormat.days(days, upTo: 4).map(\.doses.count) == [3, 2])
    #expect(MedicationFormat.days(days, upTo: 100).map(\.doses.count) == [3, 2, 3])
    #expect(MedicationFormat.days([], upTo: 100).isEmpty)
  }
}
