#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // A symptom (`SymptomContent`): entries written here, charted as the page's query charts them.
  // Each range's previous period before `previewNow`, so every period is over and full. Synthetic
  // data only.

  extension MacSnapshotTests {
    @Test(arguments: symptomsCatalog.selectedStates)
    func symptoms(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  // Severity: 0 Present, 1 Not Present, 2 Mild, 3 Moderate, 4 Severe.
  let symptomsCatalog = StateCatalog(
    "Symptoms", width: 760, minHeight: 900,
    states: [
      CatalogState("Headache, week") {
        symptom(
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
          ])
      },
      CatalogState("Headache, day") {
        symptom(
          headache, .day,
          [
            // From 10 PM the night before: charted from midnight.
            Logged(hours: -2, duration: 3.5, value: 3),
            Logged(hours: 7, duration: 2.5, value: 3),
            Logged(hours: 11.25, value: 2),
            Logged(hours: 13, duration: 1, value: 4, source: "Synthetic Watch"),
            Logged(hours: 18.5, duration: 3.5, value: 2),
            Logged(hours: 23, value: 1),
          ])
      },
      CatalogState("Headache, month") {
        // A day in two or so, at varying severity.
        let logged = (0..<31).filter { day in (day * 3) % 5 < 3 }.map { day in
          Logged(
            hours: Double(day * 24 + 8 + day % 10), duration: 1.5, value: [2, 0, 3, 4, 2][day % 5])
        }
        symptom(headache, .month, logged)
      },
      CatalogState("Headache, 6 months") {
        // A day in three or so, in spells.
        let logged = (0..<182).filter { day in (day / 12) % 3 != 2 && (day * 5) % 7 < 3 }.map {
          day in
          Logged(hours: Double(day * 24 + 9), duration: 2, value: [0, 2, 3, 4][day % 4])
        }
        symptom(headache, .sixMonths, logged)
      },
      CatalogState("Headache, year") {
        // More days some months than others.
        let logged = (0..<365).filter { day in (day * 7) % 11 < 2 + (day / 30) % 4 }.map { day in
          Logged(hours: Double(day * 24 + 9), duration: 2, value: [0, 2, 3, 4][day % 4])
        }
        symptom(headache, .year, logged)
      },
      // Presence: 0 Present, 1 Not Present. One level.
      CatalogState("Mood changes") {
        symptom(
          moodChanges, .week,
          [
            Logged(hours: 10, value: 0),
            Logged(hours: 48 + 21, value: 0),
            Logged(hours: 72 + 9, value: 1),
            Logged(hours: 144 + 12, value: 0),
          ])
      },
      // 0 Present, 1 No Change (not charted), 2 Decreased, 3 Increased: kinds of change, each in
      // its own row, so a day with two shows both.
      CatalogState("Appetite changes") {
        symptom(
          appetiteChanges, .week,
          [
            Logged(hours: 12, value: 2),
            Logged(hours: 24 + 13, value: 2),
            Logged(hours: 48 + 19, value: 1),
            Logged(hours: 96 + 8, value: 3),
            Logged(hours: 96 + 18, duration: 1, value: 2),
            Logged(hours: 120 + 20, value: 0),
          ])
      },
      // Four a day for a month: the list stops at the 100 most recent and says so, at the end.
      CatalogState("Headache, more than 100 entries") {
        let logged = (0..<(31 * 4)).map { index in
          Logged(hours: Double(index * 6 + 3), duration: 1, value: [0, 2, 3, 4][index % 4])
        }
        symptom(headache, .month, logged)
      },
      CatalogState("No headache") { symptom(headache, .week, []) },
      CatalogState("Headache loading") { symptom(headache, .week, .loading) },
      CatalogState("Headache failed") {
        symptom(headache, .week, .failed("The database couldn't be read."))
      },
    ])

  private let headache = HealthCatalog.type(id: "HKCategoryTypeIdentifierHeadache")!
  private let moodChanges = HealthCatalog.type(id: "HKCategoryTypeIdentifierMoodChanges")!
  private let appetiteChanges = HealthCatalog.type(
    id: "HKCategoryTypeIdentifierAppetiteChanges")!

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
    let interval = range.interval(offset: -1, now: previewNow, calendar: previewCalendar)
    // Only entries that overlap the period, as the query returns them.
    let entries = logged.enumerated().compactMap { index, logged -> SymptomEntry? in
      let start = interval.start.addingTimeInterval(logged.hours * 3600)
      let end = start.addingTimeInterval(logged.duration * 3600)
      guard start < interval.end, start >= interval.start || end > interval.start else {
        return nil
      }
      return SymptomEntry(
        id: "synthetic-\(index)", typeID: type.id, start: start, end: end, value: logged.value,
        sourceName: logged.source)
    }
    return SymptomChart(
      typeID: type.id, range: range, interval: interval,
      entries: entries.sorted { $0.start > $1.start }, calendar: previewCalendar)
  }

  @MainActor
  private func symptom(
    _ type: HealthDataType, _ range: ChartRange, _ logged: [Logged]
  ) -> some View {
    symptom(type, range, .loaded(chart(type, range, logged)))
  }

  @MainActor
  private func symptom(
    _ type: HealthDataType, _ range: ChartRange, _ state: SymptomContent.State
  ) -> some View {
    NavigationStack {
      SymptomContent(
        type: type, range: .constant(range), offset: .constant(-1), state: state, now: previewNow)
    }
  }
#endif
