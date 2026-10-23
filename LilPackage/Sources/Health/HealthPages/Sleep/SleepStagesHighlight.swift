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
      SleepStagesChart(
        segments: night.segments, rows: rows, calendar: calendar, barHeight: .fixed(10)
      )
      // A lane each, tall enough for its name over its bars, and the hours under them.
      .frame(
        height: CGFloat(rows.count) * SleepHighlightStyle.stageLaneHeight
          + SleepHighlightStyle.hourAxisHeight)
    }
  }
}
