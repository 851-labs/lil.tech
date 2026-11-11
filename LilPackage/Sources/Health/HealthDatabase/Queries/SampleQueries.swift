public import Foundation
import HealthCatalog
public import SQLiteData

/// Where a page of samples ends, for the next: the last sample's start and ID.
public struct SampleCursor: Hashable, Sendable {
  public var startDate: Int
  public var id: String

  public init(after sample: HealthSample) {
    startDate = sample.startDate
    id = sample.id
  }

  public init(startDate: Int, id: String) {
    self.startDate = startDate
    self.id = id
  }
}

/// An app that wrote a type's samples.
public struct SampleSource: Equatable, Identifiable, Sendable {
  /// The app's bundle ID.
  public let id: String
  public var name: String
  public var count: Int

  public init(id: String, name: String, count: Int) {
    self.id = id
    self.name = name
    self.count = count
  }
}

/// The apps and devices a type's samples came from.
public struct SampleSources: Equatable, Sendable {
  public var apps: [SampleSource]
  public var devices: [SampleDeviceSummary]

  public init(apps: [SampleSource], devices: [SampleDeviceSummary]) {
    self.apps = apps
    self.devices = devices
  }
}

/// A device that recorded a type's samples.
public struct SampleDeviceSummary: Equatable, Identifiable, Sendable {
  public var id: String { "\(device.name ?? "")/\(device.model ?? "")" }
  public var device: SampleDevice
  public var count: Int

  public init(device: SampleDevice, count: Int) {
    self.device = device
    self.count = count
  }
}

/// A sample's device, as HealthKit describes it (`HKDevice`).
public struct SampleDevice: Codable, Equatable, Sendable {
  public var name: String?
  public var manufacturer: String?
  public var model: String?
  public var hardwareVersion: String?
  public var firmwareVersion: String?
  public var softwareVersion: String?

  public init(
    name: String? = nil, manufacturer: String? = nil, model: String? = nil,
    hardwareVersion: String? = nil, firmwareVersion: String? = nil, softwareVersion: String? = nil
  ) {
    self.name = name
    self.manufacturer = manufacturer
    self.model = model
    self.hardwareVersion = hardwareVersion
    self.firmwareVersion = firmwareVersion
    self.softwareVersion = softwareVersion
  }
}

/// The version of the app that wrote a sample, and the system it ran on (`HKSourceRevision`).
public struct SampleSourceRevision: Codable, Equatable, Sendable {
  public var version: String?
  public var productType: String?
  public var operatingSystemVersion: String?
}

extension HealthSample {
  /// The device it was recorded on, if HealthKit said. For a sample read with its provenance
  /// filled in (`samplePage` does), since newer iPhones send it there (851-2674).
  public var decodedDevice: SampleDevice? {
    device.flatMap { try? JSONDecoder().decode(SampleDevice.self, from: Data($0.utf8)) }
  }

  public var decodedSourceRevision: SampleSourceRevision? {
    sourceRevision.flatMap {
      try? JSONDecoder().decode(SampleSourceRevision.self, from: Data($0.utf8))
    }
  }

  /// Its metadata as an object, empty when it has none or it isn't one.
  public var metadataObject: [String: Any] {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
    else { return [:] }
    return object
  }

  /// `HKTimeZone`, the zone it was recorded in, as text (`WorkoutMetadata.timeZoneName`'s for a
  /// sample): its details' Time Zone row shows it when it's a name (851-4179).
  public var timeZoneName: String? {
    HealthMetadataValues.value("HKTimeZone", in: metadataObject)?.string
  }

  /// Its metadata as key and value text, by key. Nested values are written as JSON.
  public var metadataEntries: [(key: String, value: String)] {
    metadataObject.map { key, value in (key, Self.metadataText(value)) }
      .sorted { $0.key < $1.key }
  }

  /// A metadata value as text, as recorded: a string as it is, a Boolean as Yes or No, a quantity
  /// or date as its description would read, and other arrays and objects as JSON.
  public static func metadataText(_ value: Any) -> String {
    let text: String
    switch value {
    case let string as String: text = string
    // JSON's `true` and `false` come back as numbers too.
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
      text = number.boolValue ? "Yes" : "No"
    case let number as NSNumber: text = number.stringValue
    // The iPhone uploads values JSON can't hold (e.g. infinity) as `null`.
    case is NSNull: text = "–"
    // A quantity, `{ value, unit }` (851-4150), as its description would read: "84.6 m".
    case let object as [String: Any] where object.count == 2:
      if let (number, unit) = HealthMetadataValues.quantityParts(object) {
        text = "\(String(format: "%.12g", number)) \(unit)"
      } else {
        text = Self.json(object)
      }
    // A date, `{ date }` (851-4150), as the iPhone wrote it: ISO 8601, in UTC.
    case let object as [String: Any] where object.count == 1 && object["date"] is String:
      text = object["date"] as? String ?? ""
    default:
      // Only arrays and objects reach here, which JSON writing accepts.
      text = Self.json(value)
    }
    return text
  }

  /// An array or object as JSON text.
  private static func json(_ value: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
      .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
  }
}

extension HealthDatabase {
  /// Up to `limit` of a type's samples, newest first, after `cursor` (the previous page's end),
  /// and only those that start in `range` if given.
  public static func samplePage(
    of type: String, in range: Range<Date>? = nil, after cursor: SampleCursor?,
    includingCursor: Bool = false, limit: Int, _ db: Database
  ) throws -> [HealthSample] {
    var page = HealthSample.where { sample in
      if let cursor, includingCursor {
        // The cursor's own sample first, whose series' values a page of them (851-4171) ended
        // inside.
        sample.type.eq(type) && sample.startDate <= cursor.startDate
          && (sample.startDate < cursor.startDate || sample.id <= cursor.id)
      } else if let cursor {
        // The plain bound first, so SQLite can seek the (type, startDate) index to it.
        sample.type.eq(type) && sample.startDate <= cursor.startDate
          && (sample.startDate < cursor.startDate || sample.id < cursor.id)
      } else {
        sample.type.eq(type)
      }
    }
    if let range {
      let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
      page = page.where { $0.startDate >= lower && $0.startDate < upper }
    }
    return
      try page
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
      .withProvenance(db)
  }

  /// The quantity series of `samples` that are series (851-4149), by ID.
  public static func quantitySeries(
    ofSamples samples: some Collection<String>, _ db: Database
  ) throws -> [String: HealthQuantitySeries] {
    guard !samples.isEmpty else { return [:] }
    let ids = Array(samples)
    return Dictionary(
      try HealthQuantitySeries.where { $0.id.in(ids) }.fetchAll(db).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
  }

  /// `samplePage` for a correlation type's correlations (blood pressure, food), with their
  /// provenance's source revision and device filled in (851-4166). The server's `samplePage`
  /// reads them alike.
  public static func correlationPage(
    of type: String, in range: Range<Date>, after cursor: SampleCursor?, limit: Int,
    _ db: Database
  ) throws -> [HealthCorrelation] {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    var page = HealthCorrelation.where {
      $0.type.eq(type) && $0.startDate >= lower && $0.startDate < upper
    }
    if let cursor {
      page = page.where {
        $0.startDate <= cursor.startDate
          && ($0.startDate < cursor.startDate || $0.id < cursor.id)
      }
    }
    return
      try page
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
      .withProvenance(db)
  }

  /// The samples in each of `correlations`, by correlation, then systolic before diastolic (blood
  /// pressure reads 118/76), then by type and ID, as the server's `correlatedValues`.
  public static func correlatedSamples(
    of correlations: [String], _ db: Database
  ) throws -> [HealthSample] {
    guard !correlations.isEmpty else { return [] }
    let systolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
    return
      try HealthSample
      .where { $0.correlationID.in(correlations.map(Optional.some)) }
      .fetchAll(db)
      .sorted {
        ($0.correlationID ?? "", $0.type == systolic ? 0 : 1, $0.type, $0.id)
          < ($1.correlationID ?? "", $1.type == systolic ? 0 : 1, $1.type, $1.id)
      }
  }

  /// The apps and devices a type's samples came from, most samples first. Read-only: which
  /// source wins is set in Health on the iPhone.
  public static func sampleSources(of type: String, _ db: Database) throws -> SampleSources {
    let apps =
      try HealthSample
      .where { $0.type.eq(type) }
      .group(by: \.sourceBundleID)
      .select { ($0.sourceBundleID, $0.sourceName.max(), $0.id.count()) }
      .fetchAll(db)
      .map { bundle, name, count in SampleSource(id: bundle, name: name ?? bundle, count: count) }
      .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    // Devices are stored as JSON whose versions change with updates: one entry per name and
    // model.
    var devices: [String: SampleDeviceSummary] = [:]
    let rows =
      try HealthSample
      .where { $0.type.eq(type) && ($0.device.isNot(nil) || $0.provenance.isNot(nil)) }
      .group { ($0.device, $0.provenance) }
      .select { ($0.device, $0.provenance, $0.id.count()) }
      .fetchAll(db)
    let provenances = try provenances(rows.compactMap { $0.1 }, db)
    for (inline, provenance, count) in rows {
      let json = inline ?? provenance.flatMap { provenances[$0]?.device }
      guard let json,
        let device = try? JSONDecoder().decode(SampleDevice.self, from: Data(json.utf8))
      else { continue }
      let summary = SampleDeviceSummary(device: device, count: 0)
      devices[summary.id, default: summary].count += count
    }
    return SampleSources(
      apps: apps, devices: devices.values.sorted { ($0.count, $1.id) > ($1.count, $0.id) })
  }

  /// The provenance records with these IDs, by ID.
  static func provenances(
    _ ids: some Sequence<String>, _ db: Database
  ) throws -> [String: HealthProvenance] {
    let ids = Array(Set(ids))
    guard !ids.isEmpty else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: try HealthProvenance.where { $0.id.in(ids) }.fetchAll(db).map {
        ($0.id, $0)
      })
  }
}

/// A record with a source revision and device, or the `HealthProvenance` that has them
/// (851-2674): samples and correlations.
protocol HasProvenance {
  var provenance: String? { get }
  var sourceRevision: String? { get set }
  var device: String? { get set }
}

extension HealthSample: HasProvenance {}
extension HealthCorrelation: HasProvenance {}

extension Array where Element: HasProvenance {
  /// The records with the source revision and device of their provenance records filled in
  /// (851-2674), so they read as if uploaded with them.
  func withProvenance(_ db: Database) throws -> Self {
    let provenances = try HealthDatabase.provenances(compactMap(\.provenance), db)
    guard !provenances.isEmpty else { return self }
    return map { record in
      guard let provenance = record.provenance.flatMap({ provenances[$0] }) else { return record }
      var record = record
      record.sourceRevision = record.sourceRevision ?? provenance.sourceRevision
      record.device = record.device ?? provenance.device
      return record
    }
  }
}
