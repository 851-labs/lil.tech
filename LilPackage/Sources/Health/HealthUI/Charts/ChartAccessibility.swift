public import SwiftUI

extension View {
  /// A period's chart as VoiceOver reads it: a group named `label` ("Steps, Aug 11 – 17, 2024")
  /// holding the chart's points, or, for a period with nothing to plot (851-3102), one element,
  /// `emptyLabel` ("No data for Aug 11 – 17, 2024", `PeriodFormat.noData`), rather than empty
  /// axes. Nothing is drawn over an empty chart: the header's value already says No Data, and the
  /// plot stays empty, with its gridlines and axes, as Health's does.
  ///
  /// The chart stays the same view either way, so a period gaining data or losing it updates the
  /// chart rather than replacing it, and only its element's children and label change. Not
  /// `accessibilityHidden` on the chart and on an element over it: on the Mac, an ancestor's
  /// `.accessibilityHidden(false)`, such as `delayedProgress`'s once loaded, shows what its
  /// descendants hid, so a chart with points also had "No data for …" (851-4042).
  public func chartAccessibility(_ label: String, isEmpty: Bool, emptyLabel: String) -> some View {
    accessibilityElement(children: isEmpty ? .ignore : .contain)
      .accessibilityLabel(isEmpty ? emptyLabel : label)
  }
}
