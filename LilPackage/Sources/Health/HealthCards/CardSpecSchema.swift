import HealthCatalog

extension HealthCards {
  /// The JSON Schema (2020-12) of the canonical spec, `Services/api/card-spec.schema.json`: every
  /// field required, unknown fields refused, and every enum spelled out (types, symbols, colors,
  /// units, aggregations, workout activities). Written in the shape Effect's
  /// `Schema.toJsonSchemaDocument` gives (`{"type": …, "enum": […]}`, `anyOf` with null last), so
  /// the server's Effect Schema of the row can be checked against it.
  ///
  /// It describes the stored form. Rules a schema can't express (a type's aggregations and
  /// units, one axis, buckets and ranges, trimming) are the validator's, which the server ports.
  static var specSchema: CardJSON {
    func strings(_ values: [String]) -> CardJSON {
      ["type": "string", "enum": .array(values.map(CardJSON.string))]
    }
    func integer(_ range: ClosedRange<Int>) -> CardJSON {
      [
        "type": "integer", "minimum": .number(Double(range.lowerBound)),
        "maximum": .number(Double(range.upperBound)),
      ]
    }
    func string(_ length: ClosedRange<Int>, pattern: String? = nil) -> CardJSON {
      var members: [(key: String, value: CardJSON)] = [
        ("type", "string"), ("minLength", .number(Double(length.lowerBound))),
        ("maxLength", .number(Double(length.upperBound))),
      ]
      if let pattern { members.append(("pattern", .string(pattern))) }
      return .object(members)
    }
    func array(_ items: CardJSON, _ count: ClosedRange<Int>, unique: Bool = false) -> CardJSON {
      var members: [(key: String, value: CardJSON)] = [
        ("type", "array"), ("items", items), ("minItems", .number(Double(count.lowerBound))),
        ("maxItems", .number(Double(count.upperBound))),
      ]
      if unique { members.append(("uniqueItems", true)) }
      return .object(members)
    }
    func nullable(_ schema: CardJSON) -> CardJSON {
      ["anyOf": [schema, ["type": "null"]]]
    }
    func object(
      _ properties: [(key: String, value: CardJSON)], description: String? = nil
    ) -> CardJSON {
      var members: [(key: String, value: CardJSON)] = []
      if let description { members.append(("description", .string(description))) }
      members += [
        ("type", "object"),
        ("properties", .object(properties)),
        ("required", .array(properties.map { .string($0.key) })),
        ("additionalProperties", false),
      ]
      return .object(members)
    }

    let id = string(1...16, pattern: "^[a-z][a-z0-9]{0,15}$")
    let text = string(textLength)
    let label = nullable(text)
    let minutes = integer(windowMinutes)
    let clockTime = string(5...5, pattern: "^([01][0-9]|2[0-3]):[0-5][0-9]$")
    let activityTypes = HealthCatalog.workoutActivityNames.keys.sorted()
    let window = nullable([
      "anyOf": [
        object([("kind", strings(["asleep"]))]),
        object([("kind", strings(["beforeSleep"])), ("minutes", minutes)]),
        object([("kind", strings(["afterWaking"])), ("minutes", minutes)]),
        object([
          ("kind", strings(["workout"])),
          (
            "activities",
            nullable(
              array(
                ["type": "integer", "enum": .array(activityTypes.map { .number(Double($0)) })],
                windowActivities, unique: true))
          ),
        ]),
        object([("kind", strings(["timeOfDay"])), ("from", clockTime), ("to", clockTime)]),
      ]
    ])
    let filterList = nullable(array(string(filterValueLength), filterListLength))
    let series = object([
      ("id", id),
      ("type", strings(chartableTypes.map(\.id))),
      ("aggregation", strings(CardSpec.Aggregation.allCases.map(\.rawValue))),
      ("window", window),
      ("filter", nullable(object([("sources", filterList), ("deviceModels", filterList)]))),
      ("label", label),
      ("hidden", ["type": "boolean"]),
    ])
    let formula: CardJSON = [
      "anyOf": [
        object([
          ("id", id), ("kind", strings(["movingAverage"])), ("of", id),
          ("points", integer(movingAveragePoints)), ("label", label),
          ("hidden", ["type": "boolean"]),
        ]),
        object([
          ("id", id), ("kind", strings(["difference"])), ("of", array(id, 2...2)),
          ("label", label), ("hidden", ["type": "boolean"]),
        ]),
      ]
    ]

    let schema = object(
      [
        (
          "version",
          [
            "type": "integer",
            "enum": .array(readableVersions.sorted().map { .number(Double($0)) }),
          ]
        ),
        (
          "display",
          object([
            ("name", text),
            ("symbol", strings(cardSymbols)),
            ("color", strings(CardColor.allCases.map(\.rawValue))),
            ("unit", nullable(strings(CardDisplayUnit.all))),
          ])
        ),
        ("series", array(series, 1...maxSeries)),
        ("formulas", array(formula, 0...maxFormulas)),
        ("bucket", strings(CardSpec.Bucket.allCases.map(\.rawValue))),
        ("range", strings(CardRange.allCases.map(\.rawValue))),
        (
          "chart",
          object([
            ("style", strings(CardSpecValidator.styles)),
            ("goal", nullable(object([("value", ["type": "number", "minimum": 0])]))),
          ])
        ),
      ],
      description:
        "A lil health card spec, version 1, in canonical form (docs/decisions/cards.md). "
        + "Generated from HealthCards by scripts/generate-health-cards: don't edit.")
    guard case .object(let members) = schema else { return schema }
    return .object(
      [
        ("$schema", "https://json-schema.org/draft/2020-12/schema"),
        ("title", "Card spec"),
      ] + members)
  }
}
