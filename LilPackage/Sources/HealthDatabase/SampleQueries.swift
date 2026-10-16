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
}

/// An app that wrote a type's samples.
public struct SampleSource: Equatable, Identifiable, Sendable {
  /// The app's bundle ID.
  public let id: String
  public var name: String
  public var count: Int
  public var latest: Date

  public init(id: String, name: String, count: Int, latest: Date) {
    self.id = id
    self.name = name
    self.count = count
    self.latest = latest
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
  /// The device it was recorded on, if HealthKit said.
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
      case let number as NSNumber: text = number.stringValue
      default:
        text =
          (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
          .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
      }
      return (key, text)
    }
    .sorted { $0.key < $1.key }
  }
}

extension HealthDatabase {
  /// Up to `limit` of a type's samples, newest first, after `cursor` (the previous page's end).
  public static func samplePage(
    of type: String, after cursor: SampleCursor?, limit: Int, _ db: Database
  ) throws -> [HealthSample] {
    try HealthSample
      .where { sample in
        if let cursor {
          sample.type.eq(type)
            && (sample.startDate < cursor.startDate
              || (sample.startDate.eq(cursor.startDate) && sample.id < cursor.id))
        } else {
          sample.type.eq(type)
        }
      }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// The apps and devices a type's samples came from, most samples first. Read-only: which
  /// source wins is set in Health on the iPhone.
  public static func sampleSources(
    of type: String, _ db: Database
  ) throws -> (apps: [SampleSource], devices: [SampleDeviceSummary]) {
    let apps =
      try HealthSample
      .where { $0.type.eq(type) }
      .group(by: \.sourceBundleID)
      .select { ($0.sourceBundleID, $0.sourceName.max(), $0.id.count(), $0.startDate.max()) }
      .fetchAll(db)
      .map { bundle, name, count, latest in
        SampleSource(
          id: bundle, name: name ?? bundle, count: count,
          latest: Date(unixMilliseconds: latest ?? 0))
      }
      .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    // Devices are stored as JSON whose versions change with updates: one entry per name and
    // model.
    var devices: [String: SampleDeviceSummary] = [:]
    let rows =
      try HealthSample
      .where { $0.type.eq(type) && $0.device.isNot(nil) }
      .group(by: \.device)
      .select { ($0.device, $0.id.count()) }
      .fetchAll(db)
    for (json, count) in rows {
      guard let json,
        let device = try? JSONDecoder().decode(SampleDevice.self, from: Data(json.utf8))
      else { continue }
      let summary = SampleDeviceSummary(device: device, count: count)
      devices[summary.id, default: summary].count += devices[summary.id] == nil ? 0 : count
    }
    return (
      apps,
      devices.values.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    )
  }
}
