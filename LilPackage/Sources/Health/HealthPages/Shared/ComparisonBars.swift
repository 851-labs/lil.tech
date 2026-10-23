public import SwiftUI

/// Two periods' values as bars on one scale, the longer full width, each under its name and value,
/// as highlights compare periods: Summary's weeks, Sleep's months (851-3109). Each bar has its own
/// line above it, so neither label can run into the other bar (851-2824): Charts placed the names
/// as axis labels, between the bars, where they collided.
public struct ComparisonBars: View {
  public struct Bar {
    let label: String
    let value: Double
    /// The value as it reads, with its unit.
    let text: String
    let color: Color

    public init(_ label: String, value: Double, text: String, color: Color) {
      self.label = label
      self.value = value
      self.text = text
      self.color = color
    }
  }

  let earlier: Bar
  let recent: Bar

  /// The earlier period first, then the recent one.
  public init(earlier: Bar, recent: Bar) {
    self.earlier = earlier
    self.recent = recent
  }

  /// The earlier period, in highlights.
  nonisolated public static let earlierColor = Color.gray.opacity(0.35)

  public var body: some View {
    let longest = max(earlier.value, recent.value)
    VStack(alignment: .leading, spacing: 8) {
      row(earlier, longest: longest)
      row(recent, longest: longest)
    }
  }

  private func row(_ bar: Bar, longest: Double) -> some View {
    // Nothing for a period of nothing, or a value that isn't one.
    let share = longest > 0 && bar.value > 0 ? min(bar.value / longest, 1) : 0
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(bar.label)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        // The value stays whole; the name gives way.
        Text(bar.text)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
          .layoutPriority(1)
      }
      .font(.caption)
      GeometryReader { proxy in
        // At least a dot, so a period of very little still shows.
        Capsule()
          .fill(bar.color)
          .frame(width: share > 0 ? max(proxy.size.width * share, Self.barHeight) : 0)
      }
      .frame(height: Self.barHeight)
    }
  }

  private static let barHeight: CGFloat = 18
}
