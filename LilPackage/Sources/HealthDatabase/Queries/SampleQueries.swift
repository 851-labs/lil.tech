public import Foundation
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

  /// Its metadata as key and value text, by key. Nested values are written as JSON.
  public var metadataEntries: [(key: String, value: String)] {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(
        with: Data(metadata.utf8)) as? [String: Any]
    else { return [] }
    return object.map { key, value in
      let text: String
      switch value {
      case let string as String: text = string
      // JSON's `true` and `false` come back as numbers too.
      case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
        text = number.boolValue ? "Yes" : "No"
      case let number as NSNumber: text = number.stringValue
      // The iPhone uploads values JSON can't hold (e.g. infinity) as `null`.
      case is NSNull: text = "–"
      default:
        // Only arrays and objects reach here, which JSON writing accepts.
        text =
          (try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
          .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
      }
      return (key, text)
    }
    .sorted { $0.key < $1.key }
  }
}

extension HealthDatabase {
  /// Up to `limit` of a type's samples, newest first, after `cursor` (the previous page's end),
  /// and only those that start in `range` if given.
  public static func samplePage(
    of type: String, in range: Range<Date>? = nil, after cursor: SampleCursor?, limit: Int,
    _ db: Database
  ) throws -> [HealthSample] {
    var page = HealthSample.where { sample in
      if let cursor {
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

extension [HealthSample] {
  /// The samples with the source revision and device of their provenance records filled in
  /// (851-2674), so they read as if uploaded with them.
  func withProvenance(_ db: Database) throws -> Self {
    let provenances = try HealthDatabase.provenances(compactMap(\.provenance), db)
    guard !provenances.isEmpty else { return self }
    return map { sample in
      guard let provenance = sample.provenance.flatMap({ provenances[$0] }) else { return sample }
      var sample = sample
      sample.sourceRevision = sample.sourceRevision ?? provenance.sourceRevision
      sample.device = sample.device ?? provenance.device
      return sample
    }
  }
}
