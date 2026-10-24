import Charts
import Dependencies
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SwiftUI

/// One card on Summary (851-3206, docs/decisions/cards.md, UI › Mac): `MetricRow` for a card. Its
/// symbol and name in its color, its headline (the lead's latest value in the display unit, and
/// when it's from) and a sparkline of the 7 buckets ending on it, in the card's chart style, with
/// a legend under them when it draws more than one line. So the welcome seed's rows read and look
/// exactly as Summary's metrics did.
///
/// Its height is the same with a value, without data ("No Data"), while it loads ("–"), when it
/// fails, and for a card of a later version, so nothing moves as Summary loads (851-3092). The
/// legend is one line that truncates, so a card with one is a line taller in every state.
struct CardRow: View {
  /// A card's headline, as its row has it.
  enum Headline: Equatable {
    case loading
    /// `nil` for No Data.
    case loaded(CardHeadline?)
    case failed(String)
  }

  let card: Card
  let headline: Headline
  let now: Date
  let calendar: Calendar
  /// Whose units the value is in (851-3116).
  @Dependency(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let spec = card.spec {
        content(spec)
      } else {
        unreadable
      }
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder private func content(_ spec: CardSpec) -> some View {
    let color = Color(paletteName: spec.display.color.rawValue)
    HStack {
      Label(spec.display.name, systemImage: spec.display.symbol)
        .foregroundStyle(color)
        .font(.headline)
      Spacer()
      if case .loaded(let headline?) = headline {
        Text(MetricFormat.date(of: headline, now: now, calendar: calendar))
          .foregroundStyle(.secondary)
      }
    }
    HStack(alignment: .bottom) {
      switch headline {
      case .loaded(let headline?):
        let unit = MetricFormat.unit(of: spec, locale: locale)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(unit.format(unit.convert(headline.value)))
            .font(.system(.title, design: .rounded).bold())
          Text(unit.label)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        sparkline(headline.data, spec: spec, color: color)
          .frame(width: 120, height: 36)
      case .loading, .loaded(nil), .failed:
        // The value's line all the same, the chart's place kept.
        placeholder
        Spacer()
        Color.clear
          .frame(width: 120, height: 36)
      }
    }
    let legend = spec.legend
    if !legend.isEmpty {
      CardLegend(lines: legend, color: color)
    }
  }

  /// What the value's line shows without a value.
  @ViewBuilder private var placeholder: some View {
    switch headline {
    case .loading:
      Text("–")
        .font(.system(.title, design: .rounded).bold())
        .foregroundStyle(.secondary)
        .accessibilityLabel("Loading")
    case .failed(let reason):
      Label("Couldn't load this card: \(reason)", systemImage: "exclamationmark.triangle")
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .help(reason)
    case .loaded:
      Text("No Data")
        .foregroundStyle(.secondary)
    }
  }

  /// A card of a later version: what this version can read of how it looks, and that it can't
  /// show it, at a row's height.
  @ViewBuilder private var unreadable: some View {
    let display = card.storedSpec["display"]
    let name = display?["name"].flatMap { if case .string(let name) = $0 { name } else { nil } }
    let symbol = display?["symbol"].flatMap {
      if case .string(let symbol) = $0, HealthCards.cardSymbols.contains(symbol) {
        symbol
      } else {
        nil
      }
    }
    let color = display?["color"].flatMap {
      if case .string(let color) = $0 { CardColor(rawValue: color) } else { nil }
    }
    HStack {
      Label(name ?? "Card", systemImage: symbol ?? "square.dashed")
        .foregroundStyle(color.map { Color(paletteName: $0.rawValue) } ?? .secondary)
        .font(.headline)
      Spacer()
    }
    HStack(alignment: .bottom) {
      Text("Update lil health to show this card")
        .lineLimit(1)
        .foregroundStyle(.secondary)
      Spacer()
      Color.clear
        .frame(width: 120, height: 36)
    }
  }

  /// The headline's buckets: the first visible series as a metric's days, the others and the
  /// formulas over them. A card showing only formulas draws its first as the lead, as a line.
  private func sparkline(_ data: CardData, spec: CardSpec, color: Color) -> Sparkline {
    func points(_ series: CardData.Series) -> [SparklinePoint] {
      series.points.map {
        SparklinePoint(
          start: $0.start, value: $0.value, minimum: $0.minimum, maximum: $0.maximum)
      }
    }
    func points(_ formula: CardData.Formula) -> [SparklinePoint] {
      formula.points.map { SparklinePoint(start: $0.start, value: $0.value) }
    }
    let series = data.series.filter { !$0.hidden }
    var formulas = data.formulas.filter { !$0.hidden }.map(points)
    let lead: [SparklinePoint]
    var style = spec.chart.style
    if let first = series.first {
      lead = points(first)
    } else {
      lead = formulas.isEmpty ? [] : formulas.removeFirst()
      style = .line
    }
    return Sparkline(
      points: lead,
      otherSeries: series.dropFirst().enumerated().map { index, series in
        SparklineSeries(
          id: series.id, mark: CardSeriesMark(index: index + 1), points: points(series))
      },
      formulas: formulas, style: style, color: color,
      domain: data.interval.start...data.interval.end, unit: data.grain.component)
  }
}

/// A card's legend (docs/decisions/cards.md, UI › The legend): each visible line's mark and label,
/// in the spec's order, on one line that truncates rather than wraps.
struct CardLegend: View {
  let lines: [CardLegendLine]
  let color: Color

  var body: some View {
    HStack(spacing: 12) {
      ForEach(lines, id: \.self) { line in
        HStack(spacing: 4) {
          mark(line.mark)
            .frame(width: 12, height: 8)
          Text(line.label)
            .lineLimit(1)
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func mark(_ mark: CardLegendLine.Mark) -> some View {
    switch mark {
    case .series(let shape):
      CardSeriesSymbol(mark: shape)
        .fill(color.opacity(shape.opacity))
        .frame(width: 7, height: 7)
    case .formula:
      Capsule()
        .fill(color)
        .frame(width: 12, height: 2)
    }
  }
}

/// A series' dot: a circle, square, triangle or diamond, by its place among the visible series.
struct CardSeriesSymbol: Shape {
  let mark: CardSeriesMark

  func path(in rect: CGRect) -> Path {
    switch mark {
    case .circle:
      return Path(ellipseIn: rect)
    case .square:
      return Path(rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06))
    case .triangle:
      return Path { path in
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
      }
    case .diamond:
      return Path { path in
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
      }
    }
  }
}

extension CardSpec {
  /// The data type whose Metric Detail shows what this card does, so Summary's row opens it until
  /// cards have their own page (851-3207): a card of one series of the type's default aggregation,
  /// without a window, filter, formula or goal, bucket `auto`, in the type's chart style and the
  /// locale's unit. The welcome seed's are, renamed, recolored or not. Others open nothing yet.
  var metricDetailType: String? {
    guard series.count == 1, let series = series.first, !series.hidden, formulas.isEmpty,
      series.window == nil, series.filter == nil, bucket == .auto, chart.goal == nil,
      display.unit == nil, let type = series.dataType, let aggregation = type.aggregation,
      series.aggregation == .defaultValue(for: aggregation), chart.style == type.chartStyle
    else { return nil }
    return type.id
  }
}
