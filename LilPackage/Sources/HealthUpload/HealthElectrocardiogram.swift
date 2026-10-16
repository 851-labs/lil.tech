public import Foundation
public import HealthKit

/// An ECG's contents, read out of `HKElectrocardiogram` and its voltage query (`init(_:store:)`),
/// so the encoding can be tested without HealthKit, which doesn't let apps create ECGs.
public struct ElectrocardiogramRecord: Equatable, Sendable {
  public var id: UUID
  /// `HKElectrocardiogram.Classification`'s raw value.
  public var classification: Int
  /// `HKElectrocardiogram.SymptomsStatus`'s raw value.
  public var symptomsStatus: Int
  /// Beats per minute.
  public var averageHeartRate: Double?
  /// Hz.
  public var samplingFrequency: Double?
  /// Apple Watch's lead I, in microvolts, in order. NaN where a measurement has no value.
  public var microvolts: [Float]
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]

  public init(
    id: UUID, classification: Int, symptomsStatus: Int, averageHeartRate: Double?,
    samplingFrequency: Double?, microvolts: [Float], provenance: [String: JSONValue]
  ) {
    self.id = id
    self.classification = classification
    self.symptomsStatus = symptomsStatus
    self.averageHeartRate = averageHeartRate
    self.samplingFrequency = samplingFrequency
    self.microvolts = microvolts
    self.provenance = provenance
  }
}

extension ElectrocardiogramRecord {
  /// Reads an ECG out of HealthKit, with its voltages. Throws `HealthReader.Locked` if the
  /// device locks meanwhile, and `HealthReader.SeriesUnavailable` if the query fails or stops
  /// short.
  public init(_ ecg: HKElectrocardiogram, store: HKHealthStore) async throws {
    let microvolt = HKUnit.voltUnit(with: .micro)
    var microvolts: [Float] = []
    microvolts.reserveCapacity(ecg.numberOfVoltageMeasurements)
    do {
      for try await measurement in HKElectrocardiogramQueryDescriptor(ecg).results(for: store) {
        let value = measurement.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(
          for: microvolt)
        microvolts.append(value.map(Float.init) ?? .nan)
      }
    } catch {
      let mapped = HealthReader.Locked.mapped(error)
      if mapped is HealthReader.Locked || mapped is CancellationError { throw mapped }
      throw HealthReader.SeriesUnavailable(
        expected: ecg.numberOfVoltageMeasurements, read: microvolts.count)
    }
    try Task.checkCancellation()
    guard microvolts.count == ecg.numberOfVoltageMeasurements else {
      throw HealthReader.SeriesUnavailable(
        expected: ecg.numberOfVoltageMeasurements, read: microvolts.count)
    }
    self.init(
      id: ecg.uuid, classification: ecg.classification.rawValue,
      symptomsStatus: ecg.symptomsStatus.rawValue,
      averageHeartRate: ecg.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute())),
      samplingFrequency: ecg.samplingFrequency?.doubleValue(for: .hertz()),
      microvolts: microvolts, provenance: HealthEncoder.provenance(of: ecg))
  }
}

extension HealthEncoder {
  public static let electrocardiogramEntity = "health_electrocardiogram"

  /// An ECG's row, and its voltages blob if it has measurements (`HealthElectrocardiogram` on
  /// the server). The row refers to the blob by its SHA-256.
  public static func electrocardiogram(_ ecg: ElectrocardiogramRecord) -> (
    mutation: HealthMutation, blob: Data?
  ) {
    let blob = ecg.microvolts.isEmpty ? nil : voltagesBlob(ecg.microvolts)
    var row = ecg.provenance
    row["classification"] = .number(Double(ecg.classification))
    row["symptomsStatus"] = .number(Double(ecg.symptomsStatus))
    row["averageHeartRate"] = JSONValue(ecg.averageHeartRate)
    row["samplingFrequency"] = JSONValue(ecg.samplingFrequency)
    row["voltageCount"] = .number(Double(ecg.microvolts.count))
    row["voltages"] = blob.map { .string(HealthBlob.sha256($0)) } ?? .null
    return (.upsert(electrocardiogramEntity, id: id(ecg.id), row: row), blob)
  }

  /// Voltages as a blob: one little-endian 32-bit float per measurement.
  public static func voltagesBlob(_ microvolts: [Float]) -> Data {
    #if _endian(little)
      microvolts.withUnsafeBytes { Data($0) }
    #else
      microvolts.map(\.bitPattern.littleEndian).withUnsafeBytes { Data($0) }
    #endif
  }
}
