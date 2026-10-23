#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Activity Rings (`ActivityRingsContent`): a made-up month of rings, the month before
  // `previewNow`'s, so every day has passed, and a later month to go to. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: activityRingsCatalog.selectedStates)
    func activityRings(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let activityRingsCatalog = StateCatalog(
    "Activity Rings", width: 760, minHeight: 900,
    states: [
      CatalogState("Activity Rings") {
        activity(.loaded(ActivityMonth(month: month, days: days)), selected: 3)
      },
      CatalogState("Goal passed twice") {
        activity(.loaded(ActivityMonth(month: month, days: days)), selected: 6)
      },
      CatalogState("Paused") {
        activity(.loaded(ActivityMonth(month: month, days: days)), selected: 4)
      },
      CatalogState("Without a Watch") {
        activity(.loaded(ActivityMonth(month: month, days: days)), selected: 7)
      },
      CatalogState("Move in minutes") {
        activity(.loaded(ActivityMonth(month: month, days: days)), selected: 12)
      },
      // June 2024 starts on a Saturday: six weeks of days, as tall as July's five and a blank.
      CatalogState("A six-week month") {
        let june = previewCalendar.dateInterval(
          of: .month, for: previewCalendar.date(byAdding: .month, value: -1, to: month.start)!)!
        activity(.loaded(ActivityMonth(month: june, days: [:])), shown: june.start)
      },
      CatalogState("No rings this month") {
        activity(.loaded(ActivityMonth(month: month, days: [:])), selected: 3)
      },
      CatalogState("Activity Rings loading") { activity(.loading) },
      // ‹ pressed: July stays, with a spinner, until June loads (851-3090).
      CatalogState("Activity Rings, loading the month before") {
        activity(
          .loaded(ActivityMonth(month: month, days: days), isUpdating: true), selected: 3,
          shown: previewCalendar.date(byAdding: .month, value: -1, to: month.start)!)
      },
      CatalogState("Activity Rings failed") {
        activity(.failed("The database couldn't be read."))
      },
    ],
    // The day starts in the same place below the grid, loading or not, whatever the month
    // (851-3090).
    sameLayout: [
      [
        "Activity Rings", "Activity Rings loading", "Activity Rings, loading the month before",
        "Goal passed twice", "Paused", "Without a Watch", "Move in minutes", "No rings this month",
        "A six-week month",
      ]
    ])

  /// July 2024.
  private let month = previewCalendar.dateInterval(
    of: .month, for: previewCalendar.date(byAdding: .month, value: -1, to: previewNow)!)!

  private func day(_ number: Int) -> Date {
    previewCalendar.date(byAdding: .day, value: number - 1, to: month.start)!
  }

  private func key(_ number: Int) -> String {
    ActivityDay.key(for: day(number), calendar: previewCalendar)
  }

  private func rings(
    _ number: Int, move: Double, exercise: Double? = 30, stand: Double? = 12,
    paused: Bool = false, minutes: Bool = false
  ) -> (String, ActivityDay) {
    (
      key(number),
      ActivityDay(
        id: key(number),
        move: ActivityRing(value: move, goal: minutes ? 30 : 500), movesInMinutes: minutes,
        exercise: exercise.map { ActivityRing(value: $0, goal: 30) },
        stand: stand.map { ActivityRing(value: $0, goal: 12) }, isPaused: paused)
    )
  }

  /// A month with goals reached, missed and passed, a paused day, and days without a Watch.
  private let days: [String: ActivityDay] = Dictionary(
    uniqueKeysWithValues: [
      rings(1, move: 520, exercise: 34, stand: 12),
      rings(2, move: 310, exercise: 12, stand: 9),
      rings(3, move: 760, exercise: 58, stand: 13),
      rings(4, move: 120, exercise: 0, stand: 4, paused: true),
      rings(5, move: 480, exercise: 28, stand: 11),
      rings(6, move: 1_120, exercise: 95, stand: 14),
      rings(7, move: 400, exercise: nil, stand: nil),
      rings(8, move: 260, exercise: nil, stand: nil),
      rings(9, move: 505, exercise: 31, stand: 12),
      rings(10, move: 220, exercise: 6, stand: 7),
      rings(11, move: 610, exercise: 42, stand: 12),
      rings(12, move: 35, exercise: 22, stand: 10, minutes: true),
    ]
      + (13...24).map {
        rings(
          $0, move: Double(300 + ($0 * 37) % 350), exercise: Double(($0 * 7) % 45),
          stand: Double(6 + $0 % 7))
      })

  /// The page on July, or on `shown` chosen while July's still showing.
  @MainActor
  private func activity(
    _ state: ActivityRingsContent.State, selected: Int? = nil, shown: Date? = nil
  ) -> some View {
    let chosen = shown.flatMap { previewCalendar.dateInterval(of: .month, for: $0) } ?? month
    return NavigationStack {
      ActivityRingsContent(
        month: chosen, selected: .constant(selected.map(day)), state: state, isLatest: false)
    }
  }
#endif
