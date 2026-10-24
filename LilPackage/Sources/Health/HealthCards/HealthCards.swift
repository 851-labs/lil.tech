public import Foundation
public import HealthCatalog

/// Cards: Summary's charts, each defined by a structured, versioned card spec that every engine
/// runs (docs/decisions/cards.md, 851-3192). This module is their shared core, free of UI and
/// databases, so the Mac, the iPhone and the tools build it: the spec, its canonicalizer and
/// validator, the curated symbols, palette and display units, the welcome seed and positions.
///
/// It's the source of truth for the server, as `HealthCatalog` is: `scripts/generate-health-cards`
/// writes `Services/api/card-spec.schema.json`, `card-seed.json` and the validation cases the
/// server's port must pass.
public enum HealthCards {
  /// The spec version this code writes.
  public static let specVersion = 1
  /// The versions it reads. A card of another shows as "Update lil health to show this card".
  public static let readableVersions: Set<Int> = [1]

  /// At most this many errors are returned for one spec.
  public static let maxErrors = 20
  /// The largest spec apps and tools write, in bytes of their JSON (UTF-8).
  public static let maxSpecBytes = 8 * 1024
  /// The largest the store accepts: a backstop, so two JSON writers' few bytes of difference never
  /// get a push refused.
  public static let storeMaxSpecBytes = 16 * 1024
  /// The most cards apps and tools let an account have.
  public static let maxCards = 100
  /// The most the store accepts, as a backstop.
  public static let storeMaxCards = 200

  public static let maxSeries = 4
  public static let maxFormulas = 2
  public static let maxVisibleLines = 4
  /// Names and labels, in Unicode code points.
  public static let textLength = 1...40
  public static let windowMinutes = 1...240
  public static let windowActivities = 1...10
  public static let movingAveragePoints = 2...30
  public static let filterListLength = 1...10
  public static let filterValueLength = 1...200

  /// The types a series may chart: quantities whose read authorization is standard, the types
  /// Metric Detail charts.
  public static let chartableTypes: [HealthDataType] = HealthCatalog.all.filter(isChartable)

  public static func isChartable(_ type: HealthDataType) -> Bool {
    type.kind == .quantity && type.readAuthorization == .standard
  }
}

extension CardSpec {
  /// Canonicalizes and validates an input spec, as apps and tools do before writing: fields with
  /// defaults may be left out, types may be named (`Heart Rate`, `HeartRate`) and workout
  /// activities too (`Running`). Throws every error, up to 20.
  public init(input: CardJSON) throws(CardSpecValidationError) {
    self = try CardSpecValidator.canonicalize(input, sizeLimit: HealthCards.maxSpecBytes).get()
  }

  /// Reads a stored spec, as decoding one does: valid and at most the store's 16 KB, so a spec
  /// another writer made just under it still reads. Throws every error, a later version's
  /// included (`unsupportedVersion`).
  public init(stored json: CardJSON) throws(CardSpecValidationError) {
    self = try CardSpecValidator.canonicalize(json, sizeLimit: HealthCards.storeMaxSpecBytes).get()
  }

  /// `init(input:)` for JSON text.
  public init(inputJSON data: Data) throws(CardSpecValidationError) {
    try self.init(input: try CardJSON(parsing: data))
  }

  /// The store's check of a spec it's asked to keep: valid, at most 16 KB, and already
  /// canonical, compared as values (`notCanonical`). Empty when it's fine.
  public static func storedErrors(_ json: CardJSON) -> [CardSpecError] {
    switch CardSpecValidator.canonicalize(json, sizeLimit: HealthCards.storeMaxSpecBytes) {
    case .failure(let error):
      return error.errors
    case .success(let spec):
      guard spec.json == json else {
        return [
          CardSpecError(
            path: "", code: .notCanonical,
            message: "The spec isn't in canonical form (a default left out, a type or activity "
              + "by name, or a name or label not trimmed): apps and tools write it canonicalized.")
        ]
      }
      return []
    }
  }
}

// MARK: - Text

extension HealthCards {
  /// Code points trimmed from names and labels: JavaScript's `String.prototype.trim()`'s, so the
  /// server's port trims alike.
  static func isTrimmed(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
      0x3000, 0xFEFF:
      true
    default: false
    }
  }

  /// Code points a name or label can't have: control characters (Cc) and line and paragraph
  /// separators.
  static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
    default: false
    }
  }

  static func trimmed(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    guard let start = scalars.firstIndex(where: { !isTrimmed($0) }),
      let end = scalars.lastIndex(where: { !isTrimmed($0) })
    else { return "" }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[start...end])
    return String(view)
  }
}
