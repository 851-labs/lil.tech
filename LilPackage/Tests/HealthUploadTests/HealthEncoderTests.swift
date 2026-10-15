import Foundation
import HealthKit
import LilAPI
import LilSync
import Testing

@testable import HealthUpload

// Synthetic data only (AGENTS.md).
private let start = Date(timeIntervalSince1970: 1_760_400_000)

private func line(_ mutation: HealthMutation) throws -> [String: Any] {
  let data = try JSONEncoder().encode(mutation)
  return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The mutation's row, as the server's generated schema decodes it.
private func row<Row: Decodable>(_ mutation: HealthMutation, as _: Row.Type) throws -> Row {
  var row = mutation.row ?? [:]
  row["id"] = .string(mutation.id)
  return try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
}

struct HealthEncoderTests {
  @Test
  func quantitySampleInTheCatalogsUnit() throws {
    let device = HKDevice(
      name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: "Watch7,1",
      firmwareVersion: nil, softwareVersion: "11.0", localIdentifier: nil,
      udiDeviceIdentifier: nil)
    let sample = HKQuantitySample(
      type: HKQuantityType(.bodyMass),
      quantity: HKQuantity(unit: .pound(), doubleValue: 154.32358),
      start: start, end: start, device: device,
      metadata: [
        HKMetadataKeyWasUserEntered: true, HKMetadataKeyTimeZone: "Europe/Bucharest",
        "Count": 3,
      ])

    let mutation = try HealthEncoder.sample(sample)
    #expect(mutation.entity == "health_sample")
    #expect(mutation.op == .upsert)
    #expect(mutation.id == sample.uuid.uuidString.lowercased())
    let decoded = try row(mutation, as: Components.Schemas.HealthSample.self)
    #expect(decoded._type == "HKQuantityTypeIdentifierBodyMass")
    #expect(decoded.unit == "kg")
    #expect(abs((decoded.value ?? 0) - 70) < 0.0001)
    #expect(decoded.startDate == 1_760_400_000_000)
    #expect(decoded.categoryValue == nil)
    #expect(decoded.correlationId == nil)

    let json = try line(mutation)
    let row = try #require(json["row"] as? [String: Any])
    let metadata = try #require(row["metadata"] as? [String: Any])
    #expect(metadata[HKMetadataKeyWasUserEntered] as? Bool == true)
    #expect(metadata["Count"] as? Int == 3)
    #expect(metadata[HKMetadataKeyTimeZone] as? String == "Europe/Bucharest")
    let encodedDevice = try #require(row["device"] as? [String: Any])
    #expect(encodedDevice["name"] as? String == "Apple Watch")
    #expect(encodedDevice["firmwareVersion"] == nil)
  }

  @Test
  func categorySample() throws {
    let sample = HKCategorySample(
      type: HKCategoryType(.sleepAnalysis),
      value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
      start: start, end: start.addingTimeInterval(1800))
    let decoded = try row(HealthEncoder.sample(sample), as: Components.Schemas.HealthSample.self)
    #expect(decoded._type == "HKCategoryTypeIdentifierSleepAnalysis")
    #expect(decoded.categoryValue == HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
    #expect(decoded.value == nil)
    #expect(decoded.unit == nil)
    #expect(decoded.endDate == 1_760_401_800_000)
  }

  @Test
  func correlationAndItsSamples() throws {
    let systolic = HKQuantitySample(
      type: HKQuantityType(.bloodPressureSystolic),
      quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 118), start: start,
      end: start)
    let diastolic = HKQuantitySample(
      type: HKQuantityType(.bloodPressureDiastolic),
      quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 76), start: start,
      end: start)
    let correlation = HKCorrelation(
      type: HKCorrelationType(.bloodPressure), start: start, end: start,
      objects: [systolic, diastolic])

    let mutations = try HealthEncoder.correlation(correlation)
    #expect(mutations.map(\.entity) == ["health_correlation", "health_sample", "health_sample"])
    let decoded = try row(mutations[0], as: Components.Schemas.HealthCorrelation.self)
    #expect(decoded._type == "HKCorrelationTypeIdentifierBloodPressure")
    for member in mutations.dropFirst() {
      let sample = try row(member, as: Components.Schemas.HealthSample.self)
      #expect(sample.correlationId == mutations[0].id)
      #expect(sample.unit == "mmHg")
    }
  }

  @Test
  func deletes() {
    let uuid = UUID()
    #expect(
      HealthEncoder.deleted(uuid)
        == .delete("health_sample", id: uuid.uuidString.lowercased()))
    #expect(HealthEncoder.deleted(uuid, correlation: true).entity == "health_correlation")
  }

  @Test
  func activitySummary() throws {
    let summary = HKActivitySummary()
    summary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 512.5)
    summary.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 600)
    summary.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 34)
    summary.exerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
    summary.appleStandHours = HKQuantity(unit: .count(), doubleValue: 9)
    summary.standHoursGoal = HKQuantity(unit: .count(), doubleValue: 12)
    let mutation = try #require(
      HealthEncoder.activitySummary(
        summary, day: DateComponents(year: 2025, month: 10, day: 4)))
    #expect(mutation.id == "2025-10-04")
    let decoded = try row(mutation, as: Components.Schemas.HealthActivitySummary.self)
    #expect(decoded.activeEnergyBurned == 512.5)
    #expect(decoded.appleExerciseTimeGoal == 30)
    #expect(decoded.appleStandHoursGoal == 12)
    #expect(decoded.appleMoveTime == nil)
    #expect(decoded.activityMoveMode == "activeEnergy")
    #expect(HealthEncoder.activitySummary(summary, day: DateComponents()) == nil)
  }

  @Test
  func characteristics() throws {
    let birthday = HealthEncoder.characteristic(
      .dateOfBirth, value: HealthEncoder.dateOfBirth(DateComponents(year: 1990, month: 4, day: 2)))
    #expect(birthday.id == "HKCharacteristicTypeIdentifierDateOfBirth")
    #expect(birthday.row == ["value": .object(["year": 1990, "month": 4, "day": 2])])
    #expect(HealthEncoder.bloodType(.abNegative) == "abNegative")
    #expect(HealthEncoder.biologicalSex(.notSet) == "notSet")
    #expect(HealthEncoder.skinType(.III) == "III")
    _ = try row(birthday, as: Components.Schemas.HealthCharacteristic.self)
  }
}

struct HealthBatchWriterTests {
  private func mutation(_ n: Int) -> HealthMutation {
    .upsert(
      "health_characteristic", id: "HKCharacteristicTypeIdentifierBloodType",
      row: ["value": .string(String(repeating: "x", count: n))])
  }

  @Test
  func cutsFilesBelowTheBound() throws {
    // About 210 bytes a line: two fit in a file.
    var writer = HealthBatchWriter(maxFileBytes: 500)
    var files: [Data] = []
    for _ in 0..<5 {
      if let file = try writer.append(mutation(100)) { files.append(file) }
    }
    if let file = try writer.finish() { files.append(file) }
    #expect(try writer.finish() == nil)

    let lines = try files.map { try String(decoding: Gzip.decompress($0), as: UTF8.self) }
    for file in lines {
      #expect(file.utf8.count <= 500)
      #expect(!file.hasSuffix("\n"))
    }
    #expect(lines.flatMap { $0.split(separator: "\n") }.count == 5)
    #expect(files.count == 3)
  }

  @Test
  func linesOverTheServersLimitAreRejected() throws {
    var writer = HealthBatchWriter()
    #expect(throws: HealthBatchWriter.LineTooLong.self) {
      try writer.append(mutation(HealthBatchWriter.maxLineBytes))
    }
    #expect(writer.pendingCount == 0)
  }
}
