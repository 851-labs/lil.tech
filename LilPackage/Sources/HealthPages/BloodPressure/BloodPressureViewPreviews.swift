import HealthDatabase
import HealthUI
import SwiftUI

// Synthetic data only (AGENTS.md): made-up readings, twice a day.

private let calendar = Calendar.current

/// Morning and evening readings over the `days` before now, one missing its diastolic.
private func readings(days: Int) -> [BloodPressureReading] {
  let today = calendar.startOfDay(for: .now)
  return (0..<days).flatMap { day -> [BloodPressureReading] in
    [8, 21].map { hour in
      let date = calendar.date(byAdding: .hour, value: hour - day * 24, to: today)!
      let wave = Double((day * 7 + hour / 3) % 13)
      return BloodPressureReading(
        id: "\(day)-\(hour)", date: date, systolic: 114 + wave,
        diastolic: day == 2 && hour == 21 ? nil : 72 + wave / 2, sourceName: "Synthetic Cuff")
    }
  }
  .filter { $0.date < .now }
  .sorted { $0.date > $1.date }
}

@MainActor
private func chart(_ range: ChartRange, days: Int) -> BloodPressureChart {
  let interval = range.interval(offset: 0, now: .now, calendar: calendar)
  let inside = readings(days: days).filter { interval.contains($0.date) }
  let points: [BloodPressurePoint]
  if range == .day || range == .week {
    points = inside.reversed().map {
      BloodPressurePoint(
        start: $0.date, systolic: $0.systolic.map { $0...$0 },
        diastolic: $0.diastolic.map { $0...$0 }, readings: [$0])
    }
  } else {
    let buckets = Dictionary(grouping: inside) {
      calendar.dateInterval(of: range.barUnit, for: $0.date)!.start
    }
    points = buckets.sorted { $0.key < $1.key }.map { start, readings in
      let systolic = readings.compactMap(\.systolic)
      let diastolic = readings.compactMap(\.diastolic)
      return BloodPressurePoint(
        start: start, systolic: systolic.min()!...systolic.max()!,
        diastolic: diastolic.isEmpty ? nil : diastolic.min()!...diastolic.max()!,
        readings: readings)
    }
  }
  return BloodPressureChart(interval: interval, points: points, readings: inside)
}

@MainActor
private func bloodPressure(_ range: ChartRange, _ state: BloodPressureContent.State) -> some View {
  NavigationStack {
    BloodPressureContent(range: .constant(range), offset: .constant(0), state: state)
  }
  .previewFrame(width: 760, height: 900)
}

#Preview("Blood pressure, week") {
  bloodPressure(.week, .loaded(chart(.week, days: 7)))
}

#Preview("Blood pressure, month") {
  bloodPressure(.month, .loaded(chart(.month, days: 31)))
}

#Preview("Blood pressure, year") {
  bloodPressure(.year, .loaded(chart(.year, days: 300)))
}

#Preview("No blood pressure") {
  bloodPressure(.week, .loaded(chart(.week, days: 0)))
}

#Preview("Blood pressure loading") {
  bloodPressure(.week, .loading)
}

#Preview("Blood pressure failed") {
  bloodPressure(.week, .failed("The database couldn't be read."))
}
