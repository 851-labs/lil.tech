/// One thing wrong with a card spec: where, which rule, and a message written for agents (what's
/// wrong, what's allowed, how to fix it). The editor shows each under its field, and the tools
/// return them all (docs/decisions/cards.md, Validation and errors).
public struct CardSpecError: Hashable, Sendable, Codable, CustomStringConvertible {
  /// Where, as a JSON path: `display.color`, `series[0].window.minutes`. Empty for the whole spec.
  public var path: String
  public var code: Code
  public var message: String

  public init(path: String, code: Code, message: String) {
    self.path = path
    self.code = code
    self.message = message
  }

  public var description: String {
    path.isEmpty ? message : "\(path): \(message)"
  }

  /// The rules. The server's port uses the same codes, and the same messages word for word
  /// (`Services/api/test/health/cards/validation-cases.json`).
  public enum Code: String, CaseIterable, Hashable, Sendable, Codable {
    // Shape
    case invalidJSON
    case invalidType
    case required
    case unknownField
    case unknownValue
    case unsupportedVersion
    // Display
    case nameLength
    case invalidCharacters
    case unknownSymbol
    case unknownColor
    case unitDimension
    // Series
    case seriesCount
    case invalidID
    case duplicateID
    case unknownType
    case notQuantity
    case unreadableType
    case aggregationNotAllowed
    case windowOnCumulative
    case windowMinutes
    case windowTime
    case unknownActivity
    case activityCount
    case duplicateActivity
    case filterOnCumulative
    case emptyFilter
    case filterList
    case filterValue
    case labelLength
    // Formulas
    case formulaCount
    case formulaPoints
    case unknownReference
    case sameSeries
    // Across fields
    case mixedUnits
    case nothingVisible
    case visibleCount
    case nightNeedsSleepWindow
    case sleepWindowBucket
    case rangeNotForBucket
    case rangesStyle
    case goalValue
    // The whole spec
    case tooLarge
    case notCanonical
    // A card's row (`CardPosition`)
    case positionLength
    case invalidPosition
  }
}

/// Every error a spec has, up to `HealthCards.maxErrors`, in the order the validator finds them.
public struct CardSpecValidationError: Error, Hashable, Sendable, CustomStringConvertible {
  public var errors: [CardSpecError]

  public init(_ errors: [CardSpecError]) {
    self.errors = errors
  }

  /// Every error as the card tools give it, the remote server's words (`specErrorsMessage` in
  /// `CardTools.ts`): a line each, with its path, `spec` for the whole spec's.
  public var toolMessage: String {
    let heading =
      errors.count == 1
      ? "The spec has 1 error. Fix it and try again:"
      : "The spec has \(errors.count) errors. Fix them and try again:"
    return ([heading] + errors.map { "- \($0.path.isEmpty ? "spec" : $0.path): \($0.message)" })
      .joined(separator: "\n")
  }

  /// Every error, a line each, so an agent can fix them all at once.
  public var description: String {
    let count = errors.count == 1 ? "1 error" : "\(errors.count) errors"
    return (["The card spec has \(count):"] + errors.map { "- \($0)" }).joined(separator: "\n")
  }
}
