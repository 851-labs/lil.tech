import Foundation
import HealthCardStore
public import HealthCards
import HealthCatalog
import HealthDatabase
import LilSync
public import SQLiteData

// The card tools' reads on the Mac (851-3216, docs/decisions/cards.md › MCP tools): `list_cards`,
// `get_card` and `preview_card`, as the remote server's (`Services/api/src/health/cards/
// CardTools.ts`, 851-3215) answer them, from this database's synced cards and with the Mac's
// engine (`HealthDatabase.cardData`), so an agent gets the same outputs and errors from both.

// MARK: - Outputs

/// A card, as the tools give it (`HealthCardItem`): its spec in canonical form and its times local
/// in the call's time zone. Each output's `encode(to:)` writes every field, `nil` as `null`, as the
/// remote server's do; the MCP server sorts the keys (`MCPServer.call`).
public struct HealthCardItem: Codable, Equatable, Sendable {
  public var id: String
  public var spec: CardJSON
  public var position: String
  /// The welcome card it started as, else `nil`.
  public var seed: String?
  public var createdAt: String
  public var updatedAt: String

  init(_ card: Card, time: ToolTime) {
    id = card.id
    // A spec this version can't read (a later version's) comes as it's stored.
    spec = card.spec?.json ?? card.storedSpec
    position = card.position
    seed = card.seed
    createdAt = time.localTime(Date(unixMilliseconds: card.createdAt))
    updatedAt = time.localTime(Date(unixMilliseconds: card.updatedAt))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(spec, forKey: .spec)
    try container.encode(position, forKey: .position)
    try container.encode(seed, forKey: .seed)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

/// A card run over one period, as the tools write it (`HealthCardData`, `CardData` in
/// `RunCard.ts`): the period's first and last days, and each point's start local with its offset.
public struct HealthCardData: Codable, Equatable, Sendable {
  public var range: String?
  public var start: String
  public var end: String
  public var timeZone: String
  public var firstWeekday: String
  public var bucket: String
  public var grain: String
  public var series: [Series]
  public var formulas: [Formula]
  public var summary: Summary?
  public var goal: Double?

  public struct Series: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var type: String
    public var aggregation: String
    public var unit: String
    public var hidden: Bool
    public var points: [Point]
  }

  public struct Point: Codable, Equatable, Sendable {
    public var start: String
    public var value: Double
    public var minimum: Double
    public var maximum: Double
    /// `nil` for totals.
    public var readings: Int?

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(start, forKey: .start)
      try container.encode(value, forKey: .value)
      try container.encode(minimum, forKey: .minimum)
      try container.encode(maximum, forKey: .maximum)
      try container.encode(readings, forKey: .readings)
    }
  }

  public struct Formula: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    /// `nil` unless the spec gives one.
    public var label: String?
    public var unit: String
    public var hidden: Bool
    public var points: [FormulaPoint]

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(kind, forKey: .kind)
      try container.encode(label, forKey: .label)
      try container.encode(unit, forKey: .unit)
      try container.encode(hidden, forKey: .hidden)
      try container.encode(points, forKey: .points)
    }
  }

  public struct FormulaPoint: Codable, Equatable, Sendable {
    public var start: String
    public var value: Double
  }

  public struct Summary: Codable, Equatable, Sendable {
    public var kind: String
    /// `nil` for a range.
    public var value: Double?
    public var minimum: Double?
    public var maximum: Double?

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(kind, forKey: .kind)
      try container.encode(value, forKey: .value)
      try container.encode(minimum, forKey: .minimum)
      try container.encode(maximum, forKey: .maximum)
    }
  }

  init(_ data: CardData, time: ToolTime, firstWeekday: ToolWeekday) {
    range = data.range?.rawValue
    start = time.localDate(data.interval.start)
    // The period ends at a midnight (or an hour), so its last moment is on its last day.
    end = time.localDate(data.interval.end.addingTimeInterval(-0.001))
    timeZone = time.name
    self.firstWeekday = firstWeekday.rawValue
    bucket = data.bucket.rawValue
    grain = data.grain.rawValue
    series = data.series.map { series in
      Series(
        id: series.id, label: series.label, type: series.type,
        aggregation: series.aggregation.rawValue, unit: series.unit.description,
        hidden: series.hidden,
        points: series.points.map { point in
          Point(
            start: time.localTime(point.start), value: point.value, minimum: point.minimum,
            maximum: point.maximum, readings: point.readings)
        })
    }
    formulas = data.formulas.map { formula in
      Formula(
        id: formula.id, kind: formula.kind.rawValue, label: formula.label,
        unit: formula.unit.description, hidden: formula.hidden,
        points: formula.points.map {
          FormulaPoint(start: time.localTime($0.start), value: $0.value)
        })
    }
    summary = data.summary.map {
      Summary(kind: $0.kind.rawValue, value: $0.value, minimum: $0.minimum, maximum: $0.maximum)
    }
    goal = data.goal
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(range, forKey: .range)
    try container.encode(start, forKey: .start)
    try container.encode(end, forKey: .end)
    try container.encode(timeZone, forKey: .timeZone)
    try container.encode(firstWeekday, forKey: .firstWeekday)
    try container.encode(bucket, forKey: .bucket)
    try container.encode(grain, forKey: .grain)
    try container.encode(series, forKey: .series)
    try container.encode(formulas, forKey: .formulas)
    try container.encode(summary, forKey: .summary)
    try container.encode(goal, forKey: .goal)
  }
}

/// `list_cards`: every card, in Summary's order.
public struct HealthCardsResult: HealthToolOutput {
  public var timeZone: String
  public var cards: [HealthCardItem]
}

/// `get_card`: a card and its data.
public struct HealthCardDataResult: HealthToolOutput {
  public var card: HealthCardItem
  public var data: HealthCardData
}

/// `preview_card`: a draft's canonical spec and its data.
public struct HealthCardPreviewResult: HealthToolOutput {
  public var spec: CardJSON
  public var data: HealthCardData
}

/// The day weeks start on, as the card tools take it. Monday when a call doesn't give one, on the
/// Mac as on the remote server.
public enum ToolWeekday: String, CaseIterable, Sendable {
  case sunday, monday, tuesday, wednesday, thursday, friday, saturday

  /// `Calendar.firstWeekday`'s number: 1 for Sunday.
  var calendarWeekday: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

// MARK: - The tools

extension HealthTools {
  /// `list_cards`: the account's cards as synced to this Mac, in Summary's order.
  public func listCards(timeZone: String? = nil, _ db: Database) throws -> HealthCardsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    try Self.requireSyncedCards(db)
    return HealthCardsResult(
      timeZone: time.name,
      cards: try HealthDatabase.cards(db).map { HealthCardItem($0, time: time) })
  }

  /// `get_card`: a card run over `range` (default its own) for the period containing `date`
  /// (`YYYY-MM-DD`, default today).
  public func getCard(
    id: String, range: CardRange? = nil, date: String? = nil, timeZone: String? = nil,
    firstWeekday: ToolWeekday? = nil, _ db: Database
  ) throws -> HealthCardDataResult {
    guard let card = try HealthCard.find(id).fetchOne(db).map(Card.init) else {
      try Self.requireSyncedCards(db)
      throw HealthToolError(Self.noCard(id))
    }
    let spec = try Self.runnable(card)
    let (data, time) = try run(
      spec, range: range, date: date, timeZone: timeZone, firstWeekday: firstWeekday, db)
    return HealthCardDataResult(card: HealthCardItem(card, time: time), data: data)
  }

  /// `preview_card`: a draft spec (any form the canonicalizer accepts, or its JSON text)
  /// validated and run without saving it, or every error it has.
  public func previewCard(
    spec input: CardJSON, range: CardRange? = nil, date: String? = nil, timeZone: String? = nil,
    firstWeekday: ToolWeekday? = nil, _ db: Database
  ) throws -> HealthCardPreviewResult {
    let spec = try Self.canonical(input)
    let (data, _) = try run(
      spec, range: range, date: date, timeZone: timeZone, firstWeekday: firstWeekday, db)
    return HealthCardPreviewResult(spec: spec.json, data: data)
  }

  /// A spec run as a tool asks for it, in the call's time zone (default the Mac's, or
  /// `defaultTimeZone`) with weeks from `firstWeekday` (default Monday). Checked in the remote
  /// server's order: the range, the time zone, then the date.
  private func run(
    _ spec: CardSpec, range: CardRange?, date: String?, timeZone: String?,
    firstWeekday: ToolWeekday?, _ db: Database
  ) throws -> (HealthCardData, ToolTime) {
    let range = try Self.runRange(spec, range)
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let firstWeekday = firstWeekday ?? .monday
    var calendar = time.calendar
    calendar.firstWeekday = firstWeekday.calendarWeekday
    let day: Date
    if let date {
      do {
        day = try time.day(date)
      } catch {
        throw HealthToolError("Unknown date: \(date). Use a day that exists, as YYYY-MM-DD.")
      }
    } else {
      day = now
    }
    let data = try HealthDatabase.cardData(
      spec, range: range, date: day, now: now, calendar: calendar, db)
    return (HealthCardData(data, time: time, firstWeekday: firstWeekday), time)
  }

  // MARK: - Checks and messages, as the remote server's

  /// Before sync has brought the account's cards to this Mac, none in the table doesn't mean the
  /// account has none (`LilSyncEngine.holds`), so the tools say so rather than answering that
  /// there are none, which could lead an agent to make them again. The remote server always has
  /// them.
  static func requireSyncedCards(_ db: Database) throws {
    guard try LilSyncEngine.holds(Card.entity, db) else {
      throw HealthToolError(
        "lil health hasn't synced the person's cards to this Mac yet. Ask them to open lil health "
          + "and sign in, then try again.")
    }
  }

  static func noCard(_ id: String) -> String {
    "No card with the id \(Self.quoted(id)). list_cards lists them."
  }

  /// A spec argument as parsed, or the tool's error for JSON text that isn't JSON (`nil`).
  public static func parsedSpec(_ json: CardJSON?) throws -> CardJSON {
    guard let json else {
      throw HealthToolError(
        specErrorsMessage([
          CardSpecError(path: "", code: .invalidJSON, message: "The spec isn't valid JSON.")
        ]))
    }
    return json
  }

  /// An input spec canonicalized, or the tool's error listing every one it has.
  public static func canonical(_ input: CardJSON) throws -> CardSpec {
    do {
      return try CardSpec(input: input)
    } catch {
      throw HealthToolError(specErrorsMessage(error.errors))
    }
  }

  /// A spec's errors as one message an agent can fix them all from: a line each, with its path
  /// (`spec` for the whole spec's).
  public static func specErrorsMessage(_ errors: [CardSpecError]) -> String {
    let heading =
      errors.count == 1
      ? "The spec has 1 error. Fix it and try again:"
      : "The spec has \(errors.count) errors. Fix them and try again:"
    return ([heading] + errors.map { "- \($0.path.isEmpty ? "spec" : $0.path): \($0.message)" })
      .joined(separator: "\n")
  }

  /// A stored card's spec, if this version can run it.
  static func runnable(_ card: Card) throws -> CardSpec {
    if let spec = card.spec { return spec }
    let version = card.storedSpec["version"] ?? .null
    if case .number(let number) = version, let whole = Int(exactly: number),
      HealthCards.readableVersions.contains(whole)
    {
      // A version this one reads, which the store's check makes unlikely: a spec it refuses.
      throw HealthToolError("lil health can't run this card's spec. Replace it with update_card.")
    }
    throw HealthToolError(
      "This card's spec is version \(version.text()), which this version of lil health can't run. "
        + "Replace it with update_card, or ask the person to update lil health.")
  }

  /// The range a run is over: the call's, if the card's bucket offers it, else the card's own.
  static func runRange(_ spec: CardSpec, _ range: CardRange?) throws -> CardRange {
    guard let range else { return spec.range }
    let ranges = spec.bucket.ranges
    guard ranges.contains(range) else {
      throw HealthToolError(
        "range \(quoted(range.rawValue)) doesn't fit the card's bucket "
          + "\(quoted(spec.bucket.rawValue)). Use \(ranges.map(\.rawValue).joined(separator: ", ")), "
          + "or leave range out for the card's own (\(spec.range.rawValue)).")
    }
    return range
  }

  /// A spec input's types, for the access log: its canonical form's, or with errors, those of its
  /// series the catalog knows by identifier or name. Each once, in order; `nil` for none.
  public static func cardTypes(of input: CardJSON) -> [String]? {
    let types: [String]
    if let spec = try? CardSpec(input: input) {
      types = spec.series.map(\.type)
    } else if case .array(let series)? = input["series"] {
      types = series.compactMap { item in
        guard case .string(let name)? = item["type"] else { return nil }
        return (HealthCatalog.type(id: name) ?? HealthCatalog.type(named: name))?.id
      }
    } else {
      types = []
    }
    var seen = Set<String>()
    let unique = types.filter { seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique
  }

  /// A spec input's range, for the access log, once it's canonical.
  public static func cardRange(of input: CardJSON) -> String? {
    (try? CardSpec(input: input))?.range.rawValue
  }

  /// A string as JSON writes it, in double quotes: as the remote server's `JSON.stringify`.
  private static func quoted(_ text: String) -> String {
    CardJSON.string(text).text()
  }
}

// MARK: - Writes (851-4014)

/// `create_card` and `update_card`: the card as written.
public struct HealthCardResult: HealthToolOutput {
  public var timeZone: String
  public var card: HealthCardItem
}

/// `delete_card`: the card deleted, by its ID.
public struct HealthCardDeletedResult: HealthToolOutput {
  public var deleted: String

  public init(deleted: String) {
    self.deleted = deleted
  }
}

/// `reorder_cards`: every card in its new order, with its position.
public struct HealthCardOrderResult: HealthToolOutput {
  public var cards: [Entry]

  public struct Entry: Codable, Equatable, Sendable {
    public var id: String
    public var position: String
  }
}

// The checks `lil-health mcp` makes before it asks the app to write (docs/decisions/cards.md › MCP
// tools, Local writes), on the cards synced to this Mac, in the remote server's order and with its
// messages, so an agent hears what's wrong at once. The app checks again, on its own cards, and
// answers with the same messages, since it may have more changes than the database the tool reads.
extension HealthTools {
  /// `create_card`'s: the spec canonicalized, the time zone, and room for another card.
  public func checkCreate(spec input: CardJSON, timeZone: String?, _ db: Database) throws
    -> CardSpec
  {
    let spec = try Self.canonical(input)
    _ = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    try Self.requireSyncedCards(db)
    guard try HealthCard.fetchCount(db) < HealthCards.maxCards else {
      throw HealthToolError(CardWriteError.tooManyCards.localizedDescription)
    }
    return spec
  }

  /// `update_card`'s: the spec canonicalized, the time zone, and the card.
  public func checkUpdate(id: String, spec input: CardJSON, timeZone: String?, _ db: Database)
    throws -> CardSpec
  {
    let spec = try Self.canonical(input)
    _ = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    try Self.requireCard(id, db)
    return spec
  }

  /// `delete_card`'s: the card.
  public func checkDelete(id: String, _ db: Database) throws {
    try Self.requireCard(id, db)
  }

  /// `reorder_cards`'s: every card's ID, once each.
  public func checkReorder(ids: [String], _ db: Database) throws {
    try Self.requireSyncedCards(db)
    do {
      _ = try Card.reordering(try HealthDatabase.cards(db), to: ids, now: now)
    } catch {
      throw HealthToolError(error.localizedDescription)
    }
  }

  /// A card written, as `create_card` and `update_card` answer once the app has stored it.
  public func cardResult(id: String, timeZone: String?, _ db: Database) throws -> HealthCardResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    guard let card = try HealthCard.find(id).fetchOne(db).map(Card.init) else {
      // Deleted again, by someone else, as soon as it was written.
      throw HealthToolError(Self.noCard(id))
    }
    return HealthCardResult(timeZone: time.name, card: HealthCardItem(card, time: time))
  }

  /// The cards in Summary's order, as `reorder_cards` answers once the app has stored it.
  public func cardOrder(_ db: Database) throws -> HealthCardOrderResult {
    HealthCardOrderResult(
      cards: try HealthDatabase.cards(db).map { .init(id: $0.id, position: $0.position) })
  }

  private static func requireCard(_ id: String, _ db: Database) throws {
    guard try HealthCard.find(id).fetchCount(db) > 0 else {
      try requireSyncedCards(db)
      throw HealthToolError(noCard(id))
    }
  }

  /// An input spec's name, for the access log: the canonical one, or as given when it has errors.
  public static func cardName(of input: CardJSON) -> String? {
    if let spec = try? CardSpec(input: input) { return spec.display.name }
    if case .string(let name)? = input["display"]?["name"] { return name }
    return nil
  }
}
