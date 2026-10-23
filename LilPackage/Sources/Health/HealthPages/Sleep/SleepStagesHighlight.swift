import Charts
import Dependencies
import HealthDatabase
import SwiftUI

/// Sleep: Stages (851-3112): last night's stages, a small hypnogram, a lane a stage, as Health's
/// highlight has it: D's chart (`SleepStagesChart`), shorter, with thinner bars.
struct SleepStagesHighlight: View {
  let night: SleepNight
  @Dependency(\.calendar) private var calendar

  var body: some View {
    SleepHighlightRow(
      title: "Sleep: Stages", systemImage: "bed.double.fill", color: SleepHighlightStyle.sleep,
      sentence: "Here are the stages you were in while you slept last night."
    ) {
      let rows = SleepFormat.rows(for: night)
      SleepStagesChart(segments: night.segments, rows: rows, barHeight: .fixed(10))
        // A lane each, tall enough for its name over its bars.
        .frame(height: CGFloat(rows.count) * 36 + 20)
        // Hours in the page's calendar and time zone, as the night's are.
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }
  }
}
