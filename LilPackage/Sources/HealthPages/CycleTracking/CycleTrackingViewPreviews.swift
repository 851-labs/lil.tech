import HealthDatabase
import HealthUI
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
  day(14): CycleDay(
    log: [
      CycleLogEntry(name: "Cervical Mucus Quality", value: "Egg White"),
      CycleLogEntry(name: "Ovulation Test Result", value: "Negative"),
    ]),
  day(16): CycleDay(
    ovulationPositive: true,
    log: [CycleLogEntry(name: "Ovulation Test Result", value: "Positive (LH Surge)")]),
  day(21): CycleDay(
    bleeding: true, log: [CycleLogEntry(name: "Bleeding After Pregnancy", value: "Light")]),
  day(17): CycleDay(
    ovulationPositive: true, symptoms: ["Bloating"],
    log: [CycleLogEntry(name: "Ovulation Test Result", value: "Estrogen Surge")]),
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
  .previewFrame(width: 760, height: 900)
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

// A day's tests and other logs, each value as Health names it (851-2830).
#Preview("A day with tests") {
  cycle(
    .loaded(CycleSnapshot(month: month, days: days, periods: periods, factors: [])),
    selected: day(14))
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
