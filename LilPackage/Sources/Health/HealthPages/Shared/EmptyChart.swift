public import SwiftUI

extension View {
  /// A chart for a period with nothing to plot (851-3102): VoiceOver reads it as one element,
  /// `label` ("No data for Aug 11 – 17, 2024", `ChartFormat.noData`), rather than empty axes.
  /// Nothing is drawn over it: the header's value already says No Data, and the plot stays empty,
  /// with its gridlines and axes, as Health's does. The chart stays the same view either way,
  /// hidden from VoiceOver under a clear element with the label, so a period gaining data or
  /// losing it updates the chart rather than replacing it.
  public func emptyChartAccessibility(_ isEmpty: Bool, label: String) -> some View {
    accessibilityHidden(isEmpty)
      .overlay {
        Color.clear
          .accessibilityElement()
          .accessibilityLabel(label)
          .accessibilityHidden(!isEmpty)
      }
  }
}

extension ChartFormat {
  /// What VoiceOver reads for an empty period's chart: "No data for Aug 11 – 17, 2024".
  public static func noData(_ period: String) -> String {
    "No data for \(period)"
  }

  /// What VoiceOver reads for a symptom's period whose entries say it wasn't there: "Not present
  /// in Aug 11 – 17, 2024".
  public static func notPresent(_ period: String) -> String {
    "Not present in \(period)"
  }
}
