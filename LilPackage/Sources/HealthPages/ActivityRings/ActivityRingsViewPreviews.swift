import HealthDatabase
import HealthUI
import SwiftUI

// Synthetic data only (AGENTS.md): a made-up month of rings.

private let calendar = Calendar.current
private let month = calendar.dateInterval(
  of: .month, for: Date(timeIntervalSince1970: 1_760_400_000))!

private func day(_ number: Int) -> Date {
  calendar.date(byAdding: .day, value: number - 1, to: month.start)!
}

private func key(_ number: Int) -> String {
  let parts = calendar.dateComponents([.year, .month, .day], from: day(number))
  return ActivityDay.key(year: parts.year!, month: parts.month!, day: parts.day!)
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

@MainActor
private func activity(_ state: ActivityRingsContent.State, selected: Int? = nil) -> some View {
  NavigationStack {
    ActivityRingsContent(month: month, selected: .constant(selected.map(day)), state: state)
  }
  .previewFrame(width: 760, height: 900)
}

#Preview("Activity Rings") {
  activity(.loaded(days), selected: 3)
}

#Preview("Goal passed twice") {
  activity(.loaded(days), selected: 6)
}

#Preview("Paused") {
  activity(.loaded(days), selected: 4)
}

#Preview("Without a Watch") {
  activity(.loaded(days), selected: 7)
}

#Preview("Move in minutes") {
  activity(.loaded(days), selected: 12)
}

#Preview("No rings this month") {
  activity(.loaded([:]), selected: 3)
}

#Preview("Activity Rings loading") {
  activity(.loading)
}

#Preview("Activity Rings failed") {
  activity(.failed("The database couldn't be read."))
}
