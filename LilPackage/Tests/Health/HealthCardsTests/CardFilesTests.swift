import Foundation
import HealthCatalog
import Testing

@testable import HealthCards

#if canImport(AppKit)
  import AppKit
#endif

/// The palette, symbols and seed, and the files the server reads, generated from this module.
struct CardFilesTests {
  static let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../../..")
    .standardized

  /// `scripts/generate-health-cards` writes these, and `scripts/format --lint` checks them too.
  @Test
  func committedFilesMatch() throws {
    for (path, contents) in HealthCards.generatedFiles() {
      let committed = try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
      #expect(committed == contents, "\(path) is out of date. Run scripts/format to regenerate it.")
    }
  }

  #if canImport(AppKit)
    /// Every curated symbol draws on the Mac. The iPhone's check is `cardSymbolsExist` in
    /// `HealthPhoneSnapshotTests`.
    @Test
    func symbolsExistOnTheMac() {
      for symbol in HealthCards.cardSymbols {
        #expect(
          NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
      }
    }
  #endif

  @Test
  func symbolsAreUnique() {
    #expect(Set(HealthCards.cardSymbols).count == HealthCards.cardSymbols.count)
  }

  /// Categories' symbols and colors are a card's defaults, so they're in the lists.
  @Test
  func categoriesUseThePalette() {
    for category in HealthCategory.allCases {
      #expect(CardColor(rawValue: category.colorName) != nil, "\(category)")
      #expect(HealthCards.cardSymbols.contains(category.symbolName), "\(category)")
    }
  }

  @Test
  func displayUnits() {
    #expect(CardDisplayUnit.dimension(ofCatalogUnit: "kg")?.units == ["kg", "lb", "st"])
    #expect(CardDisplayUnit.dimension(ofCatalogUnit: "degC")?.units == ["degC", "degF"])
    #expect(CardDisplayUnit.dimension(ofCatalogUnit: "count/min") == nil)
    #expect(Set(CardDisplayUnit.all).count == CardDisplayUnit.all.count)
    // Every catalog unit a dimension converts from is a chartable type's.
    let units = Set(HealthCards.chartableTypes.compactMap(\.unit))
    for dimension in CardDisplayUnit.dimensions {
      for unit in dimension.catalogUnits {
        #expect(units.contains(unit), "\(unit)")
      }
    }
  }

  /// The design's table (docs/decisions/cards.md, The welcome seed).
  @Test
  func welcomeSeed() {
    let rows = HealthCards.welcomeSeed.map {
      [
        $0.id, $0.seed, $0.position, $0.spec.display.name, $0.spec.display.symbol,
        $0.spec.display.color.rawValue, HealthCatalog.shortID($0.spec.series[0].type),
        $0.spec.series[0].aggregation.rawValue, $0.spec.chart.style.rawValue,
      ].joined(separator: " ")
    }
    #expect(
      rows == [
        "card_seed_steps steps a0 Steps flame.fill orange StepCount sum bars",
        "card_seed_heart_rate heart_rate a1 Heart Rate heart.fill red HeartRate avg ranges",
        "card_seed_active_energy active_energy a2 Active Energy flame.fill orange ActiveEnergyBurned sum bars",
        "card_seed_walking_running_distance walking_running_distance a3 Walking + Running Distance flame.fill orange DistanceWalkingRunning sum bars",
        "card_seed_resting_heart_rate resting_heart_rate a4 Resting Heart Rate heart.fill red RestingHeartRate avg line",
        "card_seed_weight weight a5 Weight figure purple BodyMass avg line",
      ])
    for card in HealthCards.welcomeSeed {
      #expect(card.spec.bucket == .auto && card.spec.range == .week && card.spec.formulas.isEmpty)
      #expect(card.spec.display.unit == nil && card.spec.chart.goal == nil)
      #expect(CardSpec.storedErrors(card.spec.json).isEmpty)
      #expect(CardPosition.error(card.position) == nil)
      // The entity's ID pattern (docs/decisions/cards.md, The `health_card` sync entity).
      #expect(card.id.wholeMatch(of: /card_seed_[a-z_]{1,40}/) != nil)
    }
    #expect(
      HealthCards.welcomeSeed.map(\.position)
        == (try? CardPosition.between(nil, nil, count: HealthCards.welcomeSeed.count)))
  }

  /// Every canonical spec in the cases, and the seed, matches the schema; specs of the wrong
  /// shape don't.
  @Test
  func schemaDescribesTheCanonicalForm() throws {
    let schema = HealthCards.specSchema
    var canonical = HealthCards.welcomeSeed.map(\.spec.json)
    for item in CardValidationCases.specs where item.mode == .input {
      if let spec = try? CardSpec(input: item.spec) { canonical.append(spec.json) }
    }
    #expect(canonical.count > 30)
    for spec in canonical {
      #expect(SchemaCheck.errors(spec, schema).isEmpty, "\(spec.text())")
    }
    let base = HealthCards.welcomeSeed[0].spec.json
    for wrong: CardJSON in [
      [:],
      replacing(base, "bucket", "year"),
      replacing(base, "formulas", nil),
      replacing(base, "extra", 1),
      replacing(
        base, "display", ["name": "Steps", "symbol": "flame.fill", "color": "crimson", "unit": nil]),
    ] {
      #expect(!SchemaCheck.errors(wrong, schema).isEmpty, "\(wrong.text())")
    }
  }

  @Test
  func everyCodeIsInTheSharedCases() throws {
    let cases = HealthCards.validationCasesJSON
    let text = cases.text()
    for code in CardSpecError.Code.allCases where code != .invalidJSON {
      #expect(text.contains(#""code":"\#(code.rawValue)""#), "\(code)")
    }
  }

  private func replacing(_ json: CardJSON, _ key: String, _ value: CardJSON) -> CardJSON {
    guard case .object(var members) = json else { return json }
    if let index = members.firstIndex(where: { $0.key == key }) {
      members[index].value = value
    } else {
      members.append((key, value))
    }
    return .object(members)
  }
}

/// The part of JSON Schema the generated schema uses: enough to check it describes the specs.
enum SchemaCheck {
  static func errors(_ value: CardJSON, _ schema: CardJSON, path: String = "") -> [String] {
    var errors: [String] = []
    if case .array(let options)? = schema["anyOf"] {
      if !options.contains(where: { Self.errors(value, $0, path: path).isEmpty }) {
        errors.append("\(path): no anyOf matches")
      }
    }
    if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
      errors.append("\(path): not in enum")
    }
    switch (schema["type"], value) {
    case (nil, _), ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string):
      break
    case ("integer", .number(let number)) where number == number.rounded():
      break
    case ("array", .array(let items)):
      if case .number(let min)? = schema["minItems"], Double(items.count) < min {
        errors.append("\(path): too few")
      }
      if case .number(let max)? = schema["maxItems"], Double(items.count) > max {
        errors.append("\(path): too many")
      }
      if schema["uniqueItems"] == true, Set(items).count != items.count {
        errors.append("\(path): not unique")
      }
      if let itemSchema = schema["items"] {
        for (index, item) in items.enumerated() {
          errors += Self.errors(item, itemSchema, path: "\(path)[\(index)]")
        }
      }
    case ("object", .object(let members)):
      if case .array(let required)? = schema["required"] {
        for case .string(let key) in required where value[key] == nil {
          errors.append("\(path).\(key): required")
        }
      }
      for (key, member) in members {
        if let propertySchema = schema["properties"]?[key] {
          errors += Self.errors(member, propertySchema, path: "\(path).\(key)")
        } else if schema["additionalProperties"] == false {
          errors.append("\(path).\(key): not allowed")
        }
      }
    default:
      errors.append("\(path): wrong type")
    }
    if case .string(let text) = value {
      let length = Double(text.unicodeScalars.count)
      if case .number(let min)? = schema["minLength"], length < min {
        errors.append("\(path): short")
      }
      if case .number(let max)? = schema["maxLength"], length > max {
        errors.append("\(path): long")
      }
      if case .string(let pattern)? = schema["pattern"],
        (try? Regex(pattern).firstMatch(in: text)) == nil
      {
        errors.append("\(path): pattern")
      }
    }
    if case .number(let number) = value {
      if case .number(let min)? = schema["minimum"], number < min {
        errors.append("\(path): small")
      }
      if case .number(let max)? = schema["maximum"], number > max {
        errors.append("\(path): large")
      }
    }
    return errors
  }
}
