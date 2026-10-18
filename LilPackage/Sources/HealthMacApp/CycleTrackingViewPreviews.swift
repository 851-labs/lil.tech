import HealthDatabase
import SwiftUI

// Synthetic data only (AGENTS.md): a made-up month of cycle tracking.

private let calendar = Calendar.current
private let month = calendar.dateInterval(
  of: .month, for: Date(timeIntervalSince1970: 1_760_400_000))!

private func day(_ number: Int) -> Date {
  calendar.date(byAdding: .day, value: number - 1, to: month.start)!
}

private let days: [Date: CycleDay] = [
  day(3): CycleDay(flow: .medium, symptoms: ["Abdominal Cramps", "Fatigue"]),
  day(4): CycleDay(flow: .heavy, symptoms: ["Abdominal Cramps"]),
  day(5): CycleDay(flow: .medium),
  day(6): CycleDay(flow: .light, symptoms: ["Headache"]),
  day(7): CycleDay(flow: .light),
  day(11): CycleDay(sexualActivity: true),
  day(16): CycleDay(ovulationPositive: true),
  day(17): CycleDay(ovulationPositive: true, symptoms: ["Bloating"]),
  day(24): CycleDay(spotting: true),
  day(28): CycleDay(symptoms: ["Mood Changes", "Acne"]),
]

private let periods = [
  Period(start: day(3), end: day(7)),
  Period(
    start: calendar.date(byAdding: .day, value: -29, to: day(3))!,
    end: calendar.date(byAdding: .day, value: -25, to: day(3))!, cycleLength: 29),
  Period(
    start: calendar.date(byAdding: .day, value: -57, to: day(3))!,
    end: calendar.date(byAdding: .day, value: -52, to: day(3))!, cycleLength: 28),
]

@MainActor
private func cycle(_ state: CycleTrackingContent.State, selected: Date? = nil) -> some View {
  NavigationStack {
    CycleTrackingContent(month: month, selected: .constant(selected), state: state)
  }
  .frame(width: 760, height: 900)
}

#Preview("Cycle Tracking") {
  cycle(
    .loaded(CycleSnapshot(month: month, days: days, periods: periods, factors: [])),
    selected: day(4))
}

#Preview("With factors") {
  cycle(
    .loaded(
      CycleSnapshot(
        month: month, days: days, periods: periods,
        factors: [
          CycleFactor(
            name: "Contraceptives", detail: "Oral",
            since: calendar.date(byAdding: .month, value: -8, to: month.start)!)
        ])),
    selected: day(16))
}

#Preview("A month without logs") {
  // Past cycles, but nothing this month.
  cycle(.loaded(CycleSnapshot(month: month, days: [:], periods: periods, factors: [])))
}

#Preview("No cycle data") {
  cycle(.loaded(CycleSnapshot(month: month, days: [:], periods: [], factors: [])))
}

#Preview("Cycle Tracking loading") {
  cycle(.loading)
}

#Preview("Cycle Tracking failed") {
  cycle(.failed("The database couldn't be read."))
}
