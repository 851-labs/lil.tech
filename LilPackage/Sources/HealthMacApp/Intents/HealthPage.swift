public import AppIntents
import AppKit
public import HealthCatalog
import HealthUI
import SwiftUI
import Synchronization

/// A page of lil health for Mac that its intents open (851-2892): Summary, Health Details, a
/// category, or a data type, as the sidebar offers them. Characteristics, which have no category,
/// aren't pages.
public struct HealthPage: AppEntity, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case summary
    case healthDetails
    case category(HealthCategory)
    /// A type with a category, opened in it.
    case dataType(HealthDataType)
  }

  public let kind: Kind

  public static let summary = Self(kind: .summary)
  public static let healthDetails = Self(kind: .healthDetails)

  public static func category(_ category: HealthCategory) -> Self {
    Self(kind: .category(category))
  }

  /// A data type's page. `nil` for a type without a category (a characteristic).
  public static func dataType(_ type: HealthDataType) -> Self? {
    type.category == nil ? nil : Self(kind: .dataType(type))
  }

  private init(kind: Kind) {
    self.kind = kind
  }

  /// `summary`, `health-details`, `category:<raw value>` or `type:<HealthKit identifier>`.
  public var id: String {
    switch kind {
    case .summary: "summary"
    case .healthDetails: "health-details"
    case .category(let category): "category:\(category.rawValue)"
    case .dataType(let type): "type:\(type.id)"
    }
  }

  public init?(id: String) {
    switch id {
    case "summary":
      self = .summary
    case "health-details":
      self = .healthDetails
    case let id where id.hasPrefix("category:"):
      guard let category = HealthCategory(rawValue: String(id.dropFirst("category:".count)))
      else { return nil }
      self = .category(category)
    case let id where id.hasPrefix("type:"):
      guard let type = HealthCatalog.type(id: String(id.dropFirst("type:".count))),
        let page = Self.dataType(type)
      else { return nil }
      self = page
    default:
      return nil
    }
  }

  /// The name the sidebar shows.
  public var name: String {
    switch kind {
    case .summary: "Summary"
    case .healthDetails: "Health Details"
    case .category(let category): category.name
    case .dataType(let type): type.name
    }
  }

  /// The sidebar's icon.
  var symbolName: String {
    switch kind {
    case .summary: "heart.text.square.fill"
    case .healthDetails: "person.text.rectangle.fill"
    case .category(let category): category.symbolName
    case .dataType(let type): type.category?.symbolName ?? "circle"
    }
  }

  /// The icon's color in the sidebar.
  var color: Color {
    switch kind {
    case .summary, .healthDetails: .accentColor
    case .category(let category): category.color
    case .dataType(let type): type.category?.color ?? .secondary
    }
  }

  // MARK: - Every page

  /// Summary, Health Details, then the categories: what's suggested before anything is typed.
  public static let suggested: [Self] =
    [.summary, .healthDetails] + HealthCategory.allCases.map(Self.category)

  /// Every page, types last, in the sidebar's order.
  public static let all: [Self] = suggested + browsableTypes.compactMap(Self.dataType)

  /// The types the sidebar's search finds, by category order then name. Every type in the
  /// catalog, whatever iOS version added it: the Mac shows what's synced. Characteristics, which
  /// have no category, aren't data to browse.
  static let browsableTypes: [HealthDataType] = HealthCategory.allCases.flatMap { category in
    HealthCatalog.all
      .filter { $0.category == category }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The pages a search finds: names as the sidebar's search matches them
  /// (`localizedStandardContains`), with types also found by the names `lil-health` accepts (the
  /// HealthKit identifier, or it without its prefix). Exact names first, so "Sleep" finds the
  /// category before the types that mention it.
  public static func matching(_ text: String) -> [Self] {
    let query = text.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return suggested }
    var pages = all.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if let type = HealthCatalog.type(named: query), let page = dataType(type),
      !pages.contains(page)
    {
      pages.append(page)
    }
    pages += all.filter { $0.name.localizedStandardContains(query) && !pages.contains($0) }
    return pages
  }

  // MARK: - AppEntity

  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Page")

  public static let defaultQuery = HealthPageQuery()

  public var displayRepresentation: DisplayRepresentation {
    let subtitle: LocalizedStringResource? =
      switch kind {
      case .dataType(let type): type.category.map { "\($0.name)" }
      case .summary, .healthDetails, .category: nil
      }
    return DisplayRepresentation(
      title: "\(name)", subtitle: subtitle,
      image: Self.icon(symbolName: symbolName, color: color).map {
        DisplayRepresentation.Image(data: $0, isTemplate: false)
      } ?? DisplayRepresentation.Image(systemName: symbolName))
  }

  /// The sidebar's icon in its color, as PNG data: on the Mac, an intent's symbol images can't be
  /// tinted. Rendered once per symbol and color.
  private static func icon(symbolName: String, color: Color) -> Data? {
    let key = "\(symbolName) \(color)"
    if let cached = icons.withLock({ $0[key] }) { return cached }
    let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
    guard
      let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration),
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    representation.size = NSSize(width: 128, height: 128)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    // Centered, at its own aspect ratio.
    let scale = min(112 / symbol.size.width, 112 / symbol.size.height)
    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    symbol.draw(
      in: NSRect(
        x: (128 - size.width) / 2, y: (128 - size.height) / 2, width: size.width,
        height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    let data = representation.representation(using: .png, properties: [:])
    icons.withLock { $0[key] = data }
    return data
  }

  private static let icons = Mutex<[String: Data]>([:])
}

/// Finds pages for Shortcuts, Siri and Spotlight: by ID, by name, or the suggested ones.
public struct HealthPageQuery: EntityStringQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [HealthPage] {
    identifiers.compactMap(HealthPage.init(id:))
  }

  public func entities(matching string: String) async throws -> [HealthPage] {
    HealthPage.matching(string)
  }

  public func suggestedEntities() async throws -> [HealthPage] {
    HealthPage.suggested
  }
}
