import HealthCatalog
import HealthDatabase
import SwiftUI

// Synthetic data only (AGENTS.md): entries written here, charted as the page's query charts them.
// Each range's previous period, so every period is over and full.

private let headache = HealthCatalog.type(id: "HKCategoryTypeIdentifierHeadache")!
private let moodChanges = HealthCatalog.type(id: "HKCategoryTypeIdentifierMoodChanges")!
private let appetiteChanges = HealthCatalog.type(id: "HKCategoryTypeIdentifierAppetiteChanges")!

/// An entry `hours` into the period, lasting `duration` hours.
private struct Logged {
  var hours: Double
  var duration: Double = 0
  var value: Int
  var source = "Synthetic iPhone"
}

private func chart(
  _ type: HealthDataType, _ range: ChartRange, _ logged: [Logged]
) -> SymptomChart {
  let calendar = Calendar.current
  let interval = range.interval(offset: -1, now: .now, calendar: calendar)
  // Only entries that overlap the period, as the query returns them.
  let entries = logged.enumerated().compactMap { index, logged -> SymptomEntry? in
    let start = interval.start.addingTimeInterval(logged.hours * 3600)
    let end = start.addingTimeInterval(logged.duration * 3600)
    guard start < interval.end, start >= interval.start || end > interval.start else { return nil }
    return SymptomEntry(
      id: "synthetic-\(index)", typeID: type.id, start: start,
      end: end, value: logged.value,
      sourceName: logged.source)
  }
  return SymptomChart(
    typeID: type.id, range: range, interval: interval,
    entries: entries.sorted { $0.start > $1.start }, calendar: calendar)
}

@MainActor
private func symptom(
  _ type: HealthDataType, _ range: ChartRange, _ state: SymptomContent.State
) -> some View {
  preparePreviewDatabase()
  return NavigationStack {
    SymptomContent(type: type, range: .constant(range), offset: .constant(-1), state: state)
  }
  .previewFrame(width: 760, height: 900)
}

// Severity: 0 Present, 1 Not Present, 2 Mild, 3 Moderate, 4 Severe.
#Preview("Headache, week") {
  symptom(
    headache, .week,
    .loaded(
      chart(
        headache, .week,
        [
          Logged(hours: 8, value: 2),
          Logged(hours: 24 + 9, duration: 2, value: 3),
          // The day's highest is its bar.
          Logged(hours: 24 + 15, duration: 3, value: 4, source: "Synthetic Watch"),
          Logged(hours: 72 + 10, value: 0),
          // Listed, not charted.
          Logged(hours: 96 + 20, value: 1),
          Logged(hours: 120 + 7.5, duration: 1, value: 2),
        ])))
}

#Preview("Headache, day") {
  symptom(
    headache, .day,
    .loaded(
      chart(
        headache, .day,
        [
          // From 10 PM the night before: charted from midnight.
          Logged(hours: -2, duration: 3.5, value: 3),
          Logged(hours: 7, duration: 2.5, value: 3),
          Logged(hours: 11.25, value: 2),
          Logged(hours: 13, duration: 1, value: 4, source: "Synthetic Watch"),
          Logged(hours: 18.5, duration: 3.5, value: 2),
          Logged(hours: 23, value: 1),
        ])))
}

#Preview("Headache, month") {
  // A day in two or so, at varying severity.
  let logged = (0..<31).filter { day in (day * 3) % 5 < 3 }.map { day in
    Logged(hours: Double(day * 24 + 8 + day % 10), duration: 1.5, value: [2, 0, 3, 4, 2][day % 5])
  }
  return symptom(headache, .month, .loaded(chart(headache, .month, logged)))
}

#Preview("Headache, 6 months") {
  // A day in three or so, in spells.
  let logged = (0..<182).filter { day in (day / 12) % 3 != 2 && (day * 5) % 7 < 3 }.map { day in
    Logged(hours: Double(day * 24 + 9), duration: 2, value: [0, 2, 3, 4][day % 4])
  }
  return symptom(headache, .sixMonths, .loaded(chart(headache, .sixMonths, logged)))
}

#Preview("Headache, year") {
  // More days some months than others.
  let logged = (0..<365).filter { day in (day * 7) % 11 < 2 + (day / 30) % 4 }.map { day in
    Logged(hours: Double(day * 24 + 9), duration: 2, value: [0, 2, 3, 4][day % 4])
  }
  return symptom(headache, .year, .loaded(chart(headache, .year, logged)))
}

// Presence: 0 Present, 1 Not Present. One level.
#Preview("Mood changes") {
  symptom(
    moodChanges, .week,
    .loaded(
      chart(
        moodChanges, .week,
        [
          Logged(hours: 10, value: 0),
          Logged(hours: 48 + 21, value: 0),
          Logged(hours: 72 + 9, value: 1),
          Logged(hours: 144 + 12, value: 0),
        ])))
}

// 0 Present, 1 No Change (not charted), 2 Decreased, 3 Increased: kinds of change, each in its own
// row, so a day with two shows both.
#Preview("Appetite changes") {
  symptom(
    appetiteChanges, .week,
    .loaded(
      chart(
        appetiteChanges, .week,
        [
          Logged(hours: 12, value: 2),
          Logged(hours: 24 + 13, value: 2),
          Logged(hours: 48 + 19, value: 1),
          Logged(hours: 96 + 8, value: 3),
          Logged(hours: 96 + 18, duration: 1, value: 2),
          Logged(hours: 120 + 20, value: 0),
        ])))
}

// Four a day for a month: the list stops at the 100 most recent and says so.
#Preview("Headache, more than 100 entries") {
  let logged = (0..<(31 * 4)).map { index in
    Logged(hours: Double(index * 6 + 3), duration: 1, value: [0, 2, 3, 4][index % 4])
  }
  return symptom(headache, .month, .loaded(chart(headache, .month, logged)))
}

#Preview("No headache") {
  symptom(headache, .week, .loaded(chart(headache, .week, [])))
}

#Preview("Headache loading") {
  symptom(headache, .week, .loading)
}

#Preview("Headache failed") {
  symptom(headache, .week, .failed("The database couldn't be read."))
}
