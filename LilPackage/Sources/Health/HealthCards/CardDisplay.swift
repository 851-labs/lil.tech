// What a card looks like: its color, symbol and display unit, from short lists every platform draws
// the same (docs/decisions/cards.md, Display).

/// A card's color: one of SwiftUI's system colors, by name, which adapt to light and dark mode and
/// are the same on the Mac and the iPhone. `HealthCategory.colorName` is one of these, and
/// `HealthUI` maps the names to colors.
public enum CardColor: String, CaseIterable, Codable, Hashable, Sendable {
  case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
}

extension HealthCards {
  /// The SF Symbols a card may have: names that draw on macOS 26 and iOS 26 (a test on each
  /// checks), so an agent can't pick one that draws nothing.
  public static let cardSymbols: [String] = [
    // Health's categories, so the seed looks as Summary did.
    "flame.fill", "figure", "circle.dotted.circle", "ear", "heart.fill", "pills.fill",
    "brain.head.profile", "figure.walk.motion", "carrot.fill", "lungs.fill", "bed.double.fill",
    "list.bullet.clipboard", "waveform.path.ecg", "plus",
    // Body and vitals.
    "heart.text.square.fill", "bolt.heart.fill", "waveform", "drop.fill", "thermometer.medium",
    "scalemass.fill", "ruler.fill", "eye.fill", "hand.raised.fill", "brain", "cross.case.fill",
    // Activity.
    "figure.walk", "figure.run", "figure.stairs", "figure.pool.swim", "figure.outdoor.cycle",
    "bicycle", "figure.strengthtraining.traditional", "figure.mind.and.body", "figure.cooldown",
    "bolt.fill", "timer", "stopwatch.fill",
    // Sleep and time.
    "moon.fill", "moon.zzz.fill", "zzz", "sun.max.fill", "sunrise.fill", "sunset.fill",
    "clock.fill", "alarm.fill",
    // Food.
    "fork.knife", "cup.and.saucer.fill", "waterbottle.fill", "leaf.fill",
    // General.
    "chart.line.uptrend.xyaxis", "chart.bar.fill", "gauge.with.dots.needle.50percent",
    "star.fill", "target", "flag.fill",
  ]

  /// Up to three curated symbols close to a name that isn't one, for `unknownSymbol`: those
  /// sharing the most dot-separated words with it. A word scores 2 when a symbol has it, else 1
  /// when one of the symbol's words starts with it or it starts with one (`fil` and `fill`). Ties
  /// keep the list's order.
  static func symbolsClose(to name: String) -> [String] {
    let words = name.lowercased().split(separator: ".", omittingEmptySubsequences: true)
    let scored = cardSymbols.map { symbol in
      let symbolWords = symbol.split(separator: ".")
      let score = words.reduce(0) { score, word in
        if symbolWords.contains(word) { return score + 2 }
        if symbolWords.contains(where: { $0.hasPrefix(word) || word.hasPrefix($0) }) {
          return score + 1
        }
        return score
      }
      return (symbol, score)
    }
    return
      scored
      .enumerated()
      .filter { $0.element.1 > 0 }
      .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
      .prefix(3)
      .map(\.element.0)
  }
}

/// The units a card may show its values in instead of the locale's (`display.unit`), as HealthKit's
/// unit strings, by dimension. Values are stored and computed in the catalog's units everywhere;
/// only the apps convert.
public enum CardDisplayUnit {
  public struct Dimension: Hashable, Sendable {
    public let name: String
    /// The units `display.unit` may name.
    public let units: [String]
    /// The catalog units of this dimension, which those convert from.
    public let catalogUnits: [String]
  }

  public static let dimensions: [Dimension] = [
    Dimension(name: "mass", units: ["kg", "lb", "st"], catalogUnits: ["kg", "g", "mg", "mcg"]),
    Dimension(
      name: "length", units: ["cm", "m", "km", "in", "ft", "yd", "mi"], catalogUnits: ["m", "cm"]),
    Dimension(name: "temperature", units: ["degC", "degF"], catalogUnits: ["degC"]),
    Dimension(name: "speed", units: ["km/hr", "mi/hr", "m/s"], catalogUnits: ["m/s"]),
    Dimension(name: "volume", units: ["mL", "L", "fl_oz_us"], catalogUnits: ["mL", "L"]),
    Dimension(name: "energy", units: ["kcal", "kJ"], catalogUnits: ["kcal"]),
  ]

  /// Every unit `display.unit` may name, in the dimensions' order.
  public static let all: [String] = dimensions.flatMap(\.units)

  /// The dimension of a catalog unit, or `nil` for units with no others to show (`count/min`,
  /// `%`, `ms`).
  public static func dimension(ofCatalogUnit unit: String) -> Dimension? {
    dimensions.first { $0.catalogUnits.contains(unit) }
  }
}

extension CardDisplayUnit {
  /// How a value in `catalogUnit` converts to `unit`, one of `all`: `value * scale + offset`.
  /// `nil` when they aren't of one dimension.
  public static func conversion(
    from catalogUnit: String, to unit: String
  ) -> (scale: Double, offset: Double)? {
    guard let dimension = dimension(ofCatalogUnit: catalogUnit), dimension.units.contains(unit)
    else { return nil }
    if dimension.name == "temperature" {
      return unit == "degF" ? (1.8, 32) : (1, 0)
    }
    guard let from = inBaseUnits[catalogUnit], let to = inBaseUnits[unit] else { return nil }
    return (from / to, 0)
  }

  /// Each unit in its dimension's base unit (kilograms, metres, litres, kilocalories, metres a
  /// second), by definition.
  private static let inBaseUnits: [String: Double] = [
    "kg": 1, "g": 0.001, "mg": 0.000_001, "mcg": 0.000_000_001, "lb": 0.453_592_37,
    "st": 6.350_293_18,
    "m": 1, "cm": 0.01, "km": 1000, "in": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1_609.344,
    "km/hr": 1 / 3.6, "mi/hr": 0.447_04, "m/s": 1,
    "mL": 0.001, "L": 1, "fl_oz_us": 0.029_573_529_562_5,
    "kcal": 1, "kJ": 1 / 4.184,
  ]
}
