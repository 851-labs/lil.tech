import Charts
import HealthPages
import SwiftUI

// The value axis of Metric Detail's chart, which a card's page shares (851-3207).

extension View {
  /// The chart's y-axis over `domain`, or Swift Charts' own (from zero) without one.
  @ViewBuilder func chartYDomain(_ domain: ClosedRange<Double>?) -> some View {
    if let domain {
      chartYScale(domain: domain)
    } else {
      self
    }
  }

  /// Marks on the trailing side, labeled in `shown`, the unit the chart plots: percentages for
  /// "%", a compound unit's whole inches or pounds over `domain`, else Swift Charts' own.
  func valueAxis(_ shown: MetricFormat.DisplayUnit, domain: ClosedRange<Double>?) -> some View {
    chartYAxis {
      if shown.label == "%" {
        // Plotted as percentages, 22 for 22%, as the header shows them.
        AxisMarks(
          format: FloatingPointFormatStyle<Double>.Percent().scale(1), position: .trailing)
      } else if let domain,
        let stride = shown.compoundTickStride(over: domain.upperBound - domain.lowerBound)
      {
        // Plotted in inches or pounds, and labeled as the header writes them, at whole ones,
        // so no two ticks read the same: 5′ 9″, 5′ 10″.
        AxisMarks(position: .trailing, values: .stride(by: stride)) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel {
            if let number = value.as(Double.self) { Text(shown.format(number)) }
          }
        }
      } else {
        AxisMarks(position: .trailing)
      }
    }
  }
}
