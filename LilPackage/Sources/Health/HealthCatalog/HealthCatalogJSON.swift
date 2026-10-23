import Foundation

extension HealthCatalog {
  /// The catalog as the server reads it, `Services/api/health-catalog.json` (851-2857): the
  /// categories in Browse's order, every type, and the workout activities' names. The Swift
  /// catalog is the source of truth: `scripts/generate-health-catalog` writes the file from this,
  /// and `HealthCatalogTests` checks the committed file matches.
  ///
  /// One entry per line, with fields in a fixed order, so changes diff by entry. `lil-health mcp`
  /// serves it to agents as a resource (851-2844).
  public static func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func value(_ value: any Encodable) throws -> String {
      String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    func object(_ fields: KeyValuePairs<String, any Encodable>) throws -> String {
      let pairs = try fields.map { key, field in "\(try value(key)): \(try value(field))" }
      return "{ \(pairs.joined(separator: ", ")) }"
    }

    let categories = try HealthCategory.allCases.map { category in
      try object(["id": category.rawValue, "name": category.name])
    }
    let types = try all.map { type in
      try object([
        "id": type.id,
        "name": type.name,
        "kind": type.kind.rawValue,
        "category": type.category?.rawValue,
        "alsoListedIn": HealthCategory.allCases.filter(type.alsoListedIn.contains).map(\.rawValue),
        "unit": type.unit,
        "aggregation": type.aggregation?.rawValue,
        "chartStyle": type.chartStyle?.rawValue,
        "introduced": type.introduced.description,
        "readAuthorization": type.readAuthorization.rawValue,
      ])
    }
    let workoutActivities = try workoutActivityNames.sorted { $0.key < $1.key }.map {
      try object(["activityType": $0.key, "name": $0.value])
    }
    return """
      {
        "categories": \(array(categories)),
        "types": \(array(types)),
        "workoutActivities": \(array(workoutActivities)),
        "otherWorkoutActivityName": \(try value(otherWorkoutActivityName))
      }

      """
  }

  private static func array(_ lines: [String]) -> String {
    "[\n" + lines.map { "    \($0)" }.joined(separator: ",\n") + "\n  ]"
  }

}
