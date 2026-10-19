import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

// Synthetic data only (AGENTS.md): `makePreviewHealthDatabase()`.

private let sleep = HealthCatalog.type(id: HealthDatabase.sleepType)!

@MainActor
private func detail(_ range: SleepRange, _ state: SleepDetailContent.State) -> some View {
  preparePreviewDatabase()
  return NavigationStack {
    SleepDetailContent(type: sleep, range: .constant(range), offset: .constant(0), state: state)
  }
  .frame(width: 760, height: 760)
}

@MainActor
private func previewNights(_ range: SleepRange) -> [SleepNight] {
  (try? makePreviewHealthDatabase().read { db in
    try SleepRequest(range: range, offset: 0, day: .now).fetch(db)
  }) ?? []
}

#Preview("Night") {
  detail(.day, .loaded(previewNights(.day)))
}

#Preview("Week") {
  detail(.week, .loaded(previewNights(.week)))
}

#Preview("Night without stages") {
  // E.g. an iPhone's estimate, without a Watch: asleep and awake only.
  let day = Calendar.current.startOfDay(for: .now)
  let segments = [
    SleepSegment(
      stage: .asleep, start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3 * 3600)),
    SleepSegment(
      stage: .awake, start: day.addingTimeInterval(3 * 3600),
      end: day.addingTimeInterval(3.3 * 3600)),
    SleepSegment(
      stage: .asleep, start: day.addingTimeInterval(3.3 * 3600),
      end: day.addingTimeInterval(6.5 * 3600)),
  ]
  return detail(.day, .loaded([SleepNight(day: day, segments: segments, inBed: 8 * 3600)]))
}

#Preview("No sleep") {
  detail(.day, .loaded([]))
}

#Preview("Loading") {
  detail(.day, .loading)
}

#Preview("Failed") {
  detail(.week, .failed("The database couldn't be read."))
}
