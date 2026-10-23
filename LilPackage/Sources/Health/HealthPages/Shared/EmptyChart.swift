public import SwiftUI

extension View {
  /// A chart for a period with nothing to plot (851-3102): VoiceOver reads it as one element,
  /// `label` ("No data for Aug 11 – 17, 2024", `ChartFormat.noData`), rather than empty axes.
  /// Nothing is drawn over it: the header's value already says No Data, and the plot stays empty,
  /// with its gridlines and axes, as Health's does.
  @ViewBuilder
  public func emptyChartAccessibility(_ isEmpty: Bool, label: String) -> some View {
    if isEmpty {
      accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    } else {
      self
    }
  }
}

extension ChartFormat {
  /// What VoiceOver reads for an empty period's chart: "No data for Aug 11 – 17, 2024".
  public static func noData(_ period: String) -> String {
    "No data for \(period)"
  }
}
