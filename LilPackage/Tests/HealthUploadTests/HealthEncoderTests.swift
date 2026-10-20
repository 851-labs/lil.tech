import Foundation
import GzipFiles
import HealthCatalog
import HealthKit
import LilAPI
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

/// A medication concept identifier, as HealthKit would archive one, since it has no public
/// initializer: `SyntheticConcept` archived under HealthKit's class name, then unarchived as a
/// real `HKHealthConceptIdentifier`.
private func conceptIdentifier(_ underlying: String) throws -> HKHealthConceptIdentifier {
  let archiver = NSKeyedArchiver(requiringSecureCoding: true)
  archiver.setClassName("HKHealthConceptIdentifier", for: SyntheticConcept.self)
  archiver.encode(SyntheticConcept(underlying), forKey: NSKeyedArchiveRootObjectKey)
  archiver.finishEncoding()
  return try #require(
    try NSKeyedUnarchiver.unarchivedObject(
      ofClass: HKHealthConceptIdentifier.self, from: archiver.encodedData))
}

/// Encodes what `HKHealthConceptIdentifier` does (on macOS 27): its domain and underlying
/// identifier.
@objc(LilSyntheticConcept)
private final class SyntheticConcept: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let underlying: String

  init(_ underlying: String) {
    self.underlying = underlying
  }

  init?(coder: NSCoder) { nil }

  func encode(with coder: NSCoder) {
    coder.encode(HKHealthConceptDomain.medication.rawValue as NSString, forKey: "DomainKey")
    coder.encode(underlying as NSString, forKey: "UnderlyingIdentifierKey")
  }
}

struct HealthEncoderTests {
  /// Pinned: a sample's start is part of how the server finds it.
  @Test
  func datesRoundToTheNearestMillisecond() {
    // Exact in binary: 1/1024 s is 0.977 ms, and 3/1024 s is 2.93 ms.
    #expect(HealthEncoder.milliseconds(Date(timeIntervalSince1970: 1.0 / 1024)) == 1)
    #expect(HealthEncoder.milliseconds(Date(timeIntervalSince1970: 3.0 / 1024)) == 3)
    #expect(
      HealthEncoder.milliseconds(Date(timeIntervalSince1970: 1_760_400_000)) == 1_760_400_000_000)
  }

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
    // Left out, so it can't clear a correlation's link.
    #expect(mutation.row?["correlationId"] == nil)

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
  func numbersJSONCantHoldBecomeNull() throws {
    let encoded = try JSONEncoder().encode(
      JSONValue.array([.number(.nan), .number(.infinity), 1.5]))
    #expect(String(decoding: encoded, as: UTF8.self) == "[null,null,1.5]")
    #expect(HealthEncoder.json(NSNumber(value: Double.nan)) == .null)
    #expect(HealthEncoder.json(NSNumber(value: true)) == .bool(true))
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
    let gregorian = Calendar(identifier: .gregorian)
    let mutation = try #require(
      HealthEncoder.activitySummary(
        summary, day: DateComponents(year: 2025, month: 10, day: 4), calendar: gregorian))
    #expect(mutation.id == "2025-10-04")
    let decoded = try row(mutation, as: Components.Schemas.HealthActivitySummary.self)
    #expect(decoded.activeEnergyBurned == 512.5)
    #expect(decoded.appleExerciseTimeGoal == 30)
    #expect(decoded.appleStandHoursGoal == 12)
    #expect(decoded.appleMoveTime == nil)
    #expect(decoded.activityMoveMode == "activeEnergy")
    #expect(
      HealthEncoder.activitySummary(summary, day: DateComponents(), calendar: gregorian) == nil)

    // Reiwa 7 in the Japanese calendar is 2025.
    var japanese = Calendar(identifier: .japanese)
    japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let reiwa = DateComponents(era: 236, year: 7, month: 10, day: 4)
    #expect(
      HealthEncoder.activitySummary(summary, day: reiwa, calendar: japanese)?.id == "2025-10-04")
  }

  @Test
  func workoutWithActivitiesEventsAndStatistics() throws {
    // Provenance comes from a sample here, since HKWorkout's initializers are deprecated.
    var provenance = HealthEncoder.provenance(
      of: HKQuantitySample(
        type: HKQuantityType(.heartRate),
        quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 1),
        start: start, end: start.addingTimeInterval(1800)))
    provenance["metadata"] = .object(["HKIndoorWorkout": .bool(false)])
    let heartRate = WorkoutRecord.Statistic(
      type: "HKQuantityTypeIdentifierHeartRate", unit: "count/min", average: 151, minimum: 98,
      maximum: 178, mostRecent: 160)
    let energy = WorkoutRecord.Statistic(
      type: "HKQuantityTypeIdentifierActiveEnergyBurned", unit: "kcal", sum: 312.5)
    let workout = WorkoutRecord(
      id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000A1")!,
      activityType: HKWorkoutActivityType.running.rawValue, duration: 1740,
      activities: [
        .init(
          id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000A2")!,
          activityType: HKWorkoutActivityType.running.rawValue, startDate: start,
          endDate: start.addingTimeInterval(1800), duration: 1740, metadata: nil,
          statistics: [heartRate])
      ],
      events: [
        .init(
          type: HKWorkoutEventType.pause.rawValue, startDate: start.addingTimeInterval(600),
          endDate: start.addingTimeInterval(660), metadata: nil)
      ],
      statistics: [energy, heartRate], provenance: provenance)

    let mutation = HealthEncoder.workout(workout)
    #expect(mutation.entity == "health_workout")
    #expect(mutation.id == "6f1c2a40-0000-4000-8000-0000000000a1")
    // It's what the server's schema accepts.
    let decoded = try row(mutation, as: Components.Schemas.HealthWorkout.self)
    #expect(decoded.activityType == 37)
    #expect(decoded.duration == 1740)
    #expect(decoded.startDate == 1_760_400_000_000)
    #expect(decoded.endDate == 1_760_401_800_000)
    let encoded = try line(mutation)
    let row = try #require(encoded["row"] as? [String: Any])
    let activities = try #require(row["activities"] as? [[String: Any]])
    #expect(activities.first?["id"] as? String == "6f1c2a40-0000-4000-8000-0000000000a2")
    #expect(activities.first?["endDate"] as? Double == 1_760_401_800_000)
    let events = try #require(row["events"] as? [[String: Any]])
    #expect(events.first?["type"] as? Double == 1)
    #expect(events.first?["startDate"] as? Double == 1_760_400_600_000)
    let statistics = try #require(row["statistics"] as? [String: [String: Any]])
    #expect(statistics["HKQuantityTypeIdentifierActiveEnergyBurned"]?["sum"] as? Double == 312.5)
    #expect(statistics["HKQuantityTypeIdentifierHeartRate"]?["average"] as? Double == 151)
    #expect(statistics["HKQuantityTypeIdentifierHeartRate"]?["sum"] is NSNull)
  }

  @Test
  func stateOfMind() throws {
    let log = HKStateOfMind(
      date: start, kind: .dailyMood, valence: 0.4, labels: [.happy, .grateful],
      associations: [.family])
    let mutation = HealthEncoder.stateOfMind(log)
    #expect(mutation.entity == "health_state_of_mind")
    let decoded = try row(mutation, as: Components.Schemas.HealthStateOfMind.self)
    #expect(decoded.kind == HKStateOfMind.Kind.dailyMood.rawValue)
    #expect(decoded.valence == 0.4)
    #expect(decoded.valenceClassification == log.valenceClassification.rawValue)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    #expect(
      encoded["labels"] as? [Int]
        == [HKStateOfMind.Label.happy.rawValue, HKStateOfMind.Label.grateful.rawValue])
    #expect(encoded["associations"] as? [Int] == [HKStateOfMind.Association.family.rawValue])
  }

  @Test
  func scoredAssessments() throws {
    let gad7 = HKGAD7Assessment(
      date: start,
      answers: [
        .notAtAll, .severalDays, .notAtAll, .moreThanHalfTheDays, .notAtAll, .notAtAll,
        .nearlyEveryDay,
      ])
    let mutation = try HealthEncoder.scoredAssessment(gad7)
    #expect(mutation.entity == "health_scored_assessment")
    let decoded = try row(mutation, as: Components.Schemas.HealthScoredAssessment.self)
    #expect(decoded._type == "HKScoredAssessmentTypeIdentifierGAD7")
    #expect(decoded.score == gad7.score)
    #expect(decoded.risk == gad7.risk.rawValue)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    #expect(encoded["answers"] as? [Int] == gad7.answers.map(\.rawValue))

    let phq9 = HKPHQ9Assessment(
      date: start, answers: Array(repeating: .severalDays, count: 9))
    let phq9Row = try row(
      try HealthEncoder.scoredAssessment(phq9), as: Components.Schemas.HealthScoredAssessment.self)
    #expect(phq9Row._type == "HKScoredAssessmentTypeIdentifierPHQ9")
    #expect(phq9Row.score == 9)
  }

  @Test
  func audiogram() throws {
    let decibels = HKUnit.decibelHearingLevel()
    let test = { (side: HKAudiogramSensitivityTestSide, value: Double) in
      try HKAudiogramSensitivityTest(
        sensitivity: HKQuantity(unit: decibels, doubleValue: value), type: .air, masked: false,
        side: side,
        clampingRange: try HKAudiogramSensitivityPointClampingRange(
          lowerBound: nil, upperBound: 90))
    }
    let points = try [
      HKAudiogramSensitivityPoint(
        frequency: HKQuantity(unit: .hertz(), doubleValue: 500),
        tests: [try test(.left, 10)]),
      HKAudiogramSensitivityPoint(
        frequency: HKQuantity(unit: .hertz(), doubleValue: 4000),
        tests: [try test(.left, 35), try test(.right, 30)]),
    ]
    let sample = HKAudiogramSample(
      sensitivityPoints: points, start: start, end: start, device: nil, metadata: nil)
    let mutation = HealthEncoder.audiogram(sample)
    #expect(mutation.entity == "health_audiogram")
    _ = try row(mutation, as: Components.Schemas.HealthAudiogram.self)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    let encodedPoints = try #require(encoded["points"] as? [[String: Any]])
    #expect(encodedPoints.map { $0["frequency"] as? Double } == [500, 4000])
    let tests = try #require(encodedPoints.last?["tests"] as? [[String: Any]])
    #expect(tests.map { $0["sensitivity"] as? Double } == [35, 30])
    #expect(
      tests.map { $0["side"] as? Int }
        == [
          HKAudiogramSensitivityTestSide.left.rawValue,
          HKAudiogramSensitivityTestSide.right.rawValue,
        ])
    #expect(tests.first?["type"] as? Int == HKAudiogramConductionType.air.rawValue)
    #expect(tests.first?["masked"] as? Bool == false)
    #expect(tests.first?["clampingUpper"] as? Double == 90)
    #expect(tests.first?["clampingLower"] is NSNull)
  }

  @Test
  func glassesPrescription() throws {
    let diopters = HKUnit.diopter()
    let millimeters = HKUnit.meterUnit(with: .milli)
    let prism = HKVisionPrism(
      verticalAmount: HKQuantity(unit: .prismDiopter(), doubleValue: 1), verticalBase: .up,
      horizontalAmount: HKQuantity(unit: .prismDiopter(), doubleValue: 0.5),
      horizontalBase: .in, eye: .right)
    let right = HKGlassesLensSpecification(
      sphere: HKQuantity(unit: diopters, doubleValue: -2.25),
      cylinder: HKQuantity(unit: diopters, doubleValue: -0.5),
      axis: HKQuantity(unit: .degreeAngle(), doubleValue: 90), addPower: nil,
      vertexDistance: HKQuantity(unit: millimeters, doubleValue: 12), prism: prism,
      farPupillaryDistance: HKQuantity(unit: millimeters, doubleValue: 32),
      nearPupillaryDistance: nil)
    let expires = start.addingTimeInterval(2 * 365 * 86_400)
    let prescription = HKGlassesPrescription(
      rightEyeSpecification: right, leftEyeSpecification: nil, dateIssued: start,
      expirationDate: expires, device: nil, metadata: nil)
    let mutation = try #require(HealthEncoder.visionPrescription(prescription))
    #expect(mutation.entity == "health_vision_prescription")
    // Its source revision and device go up once per file, as other records' do.
    #expect(HealthBatchWriter.provenanceEntities.contains(mutation.entity))
    _ = try row(mutation, as: Components.Schemas.HealthVisionPrescription.self)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    #expect(encoded["prescriptionType"] as? Int == 1)
    #expect(encoded["startDate"] as? Double == HealthEncoder.milliseconds(start))
    #expect(encoded["endDate"] as? Double == HealthEncoder.milliseconds(start))
    #expect(encoded["expirationDate"] as? Double == HealthEncoder.milliseconds(expires))
    #expect(encoded["brand"] is NSNull)
    #expect(encoded["leftEye"] is NSNull)
    let eye = try #require(encoded["rightEye"] as? [String: Any])
    #expect(eye["sphere"] as? Double == -2.25)
    #expect(eye["axis"] as? Double == 90)
    #expect(eye["addPower"] is NSNull)
    #expect(eye["vertexDistance"] as? Double == 12)
    #expect(eye["nearPupillaryDistance"] is NSNull)
    let encodedPrism = try #require(eye["prism"] as? [String: Any])
    #expect(encodedPrism["verticalAmount"] as? Double == 1)
    #expect(encodedPrism["verticalBase"] as? Int == HKPrismBase.up.rawValue)
    #expect(encodedPrism["horizontalBase"] as? Int == HKPrismBase.in.rawValue)
  }

  @Test
  func contactsPrescription() throws {
    let diopters = HKUnit.diopter()
    let millimeters = HKUnit.meterUnit(with: .milli)
    let lens = { (sphere: Double) in
      HKContactsLensSpecification(
        sphere: HKQuantity(unit: diopters, doubleValue: sphere), cylinder: nil, axis: nil,
        addPower: nil, baseCurve: HKQuantity(unit: millimeters, doubleValue: 8.6),
        diameter: HKQuantity(unit: millimeters, doubleValue: 14.2))
    }
    let prescription = HKContactsPrescription(
      rightEyeSpecification: lens(-2.25), leftEyeSpecification: lens(-2), brand: "Synthetic",
      dateIssued: start, expirationDate: nil, device: nil, metadata: nil)
    let mutation = try #require(HealthEncoder.visionPrescription(prescription))
    _ = try row(mutation, as: Components.Schemas.HealthVisionPrescription.self)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    #expect(encoded["prescriptionType"] as? Int == 2)
    #expect(encoded["brand"] as? String == "Synthetic")
    #expect(encoded["expirationDate"] is NSNull)
    let left = try #require(encoded["leftEye"] as? [String: Any])
    #expect(left["sphere"] as? Double == -2)
    #expect(left["baseCurve"] as? Double == 8.6)
    #expect(left["diameter"] as? Double == 14.2)
    #expect(left["prism"] == nil)
  }

  @Test
  func visionPrescriptionsArentPagedThroughWithAnchors() {
    // Health shares them one by one, at any time: they're read whole each run instead.
    let types = HealthBackfillType.all(availableOn: .ios(26))
    #expect(!types.contains { $0.id == "HKVisionPrescriptionTypeIdentifier" })
  }

  @Test
  func medicationKeyedByItsConcept() throws {
    let record = MedicationRecord(
      id: String(repeating: "a", count: 64), name: "Synthetic 10 mg Tablet",
      nickname: "Morning pill", generalForm: HKMedicationGeneralForm.tablet.rawValue,
      isArchived: false, hasSchedule: true,
      codings: [
        .init(system: "http://example.com/b", version: nil, code: "2"),
        .init(system: "http://example.com/a", version: "1", code: "1"),
      ])
    let mutation = HealthEncoder.medication(record)
    #expect(mutation.entity == "health_medication")
    #expect(mutation.id == record.id)
    // Not a sample: it has no source revision or device.
    #expect(!HealthBatchWriter.provenanceEntities.contains(mutation.entity))
    let decoded = try row(mutation, as: Components.Schemas.HealthMedication.self)
    #expect(decoded.name == "Synthetic 10 mg Tablet")
    #expect(decoded.nickname == "Morning pill")
    #expect(decoded.generalForm == "tablet")
    #expect(!decoded.isArchived)
    #expect(decoded.hasSchedule)
    let encoded = try #require(try line(mutation)["row"] as? [String: Any])
    // Sorted, so the same medication always hashes the same.
    let codings = try #require(encoded["codings"] as? [[String: Any]])
    #expect(
      codings.map { $0["system"] as? String } == ["http://example.com/a", "http://example.com/b"])
    #expect(codings.first?["version"] as? String == "1")
    #expect(codings.last?["version"] is NSNull)
  }

  @Test
  func medicationsAreOnePerConceptCurrentOnesFirst() {
    let medication = { (nickname: String, isArchived: Bool) in
      MedicationRecord(
        id: "concept", name: "Synthetic", nickname: nickname, generalForm: "tablet",
        isArchived: isArchived, hasSchedule: false, codings: [])
    }
    let medications = HealthEncoder.medications([
      medication("Archived", true), medication("Current", false),
    ])
    #expect(medications.count == 1)
    #expect(medications.first?.row?["nickname"] == "Current")
  }

  @Test
  func medicationDoseEvent() throws {
    let scheduled = start.addingTimeInterval(-900)
    let dose = MedicationDoseRecord(
      id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000C1")!,
      medication: String(repeating: "a", count: 64),
      logStatus: HKMedicationDoseEvent.LogStatus.taken.rawValue,
      scheduleType: HKMedicationDoseEvent.ScheduleType.schedule.rawValue,
      scheduledDate: scheduled, scheduledDoseQuantity: 2, doseQuantity: 1, unit: "count",
      provenance: HealthEncoder.provenance(
        of: HKQuantitySample(
          type: HKQuantityType(.heartRate),
          quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 1),
          start: start, end: start)))
    let mutation = HealthEncoder.medicationDose(dose)
    #expect(mutation.entity == "health_medication_dose")
    #expect(mutation.id == "6f1c2a40-0000-4000-8000-0000000000c1")
    // Its source revision and device go up once per file, as other samples' do.
    #expect(HealthBatchWriter.provenanceEntities.contains(mutation.entity))
    let decoded = try row(mutation, as: Components.Schemas.HealthMedicationDose.self)
    #expect(decoded.medication == dose.medication)
    #expect(decoded.logStatus == 4)
    #expect(decoded.scheduleType == 2)
    #expect(decoded.scheduledDate == Int(HealthEncoder.milliseconds(scheduled)))
    #expect(decoded.scheduledDoseQuantity == 2)
    #expect(decoded.doseQuantity == 1)
    #expect(decoded.unit == "count")
    #expect(decoded.startDate == 1_760_400_000_000)

    // As needed, with no schedule.
    var asNeeded = dose
    asNeeded.scheduleType = HKMedicationDoseEvent.ScheduleType.asNeeded.rawValue
    asNeeded.scheduledDate = nil
    asNeeded.scheduledDoseQuantity = nil
    let encoded = try #require(
      try line(HealthEncoder.medicationDose(asNeeded))["row"] as? [String: Any])
    #expect(encoded["scheduleType"] as? Int == 1)
    #expect(encoded["scheduledDate"] is NSNull)
    #expect(encoded["scheduledDoseQuantity"] is NSNull)
  }

  @Test
  func conceptIDsMatchWhenTheConceptsDo() throws {
    let a = try conceptIdentifier("synthetic-a")
    let id = HealthEncoder.conceptID(a)
    #expect(id.wholeMatch(of: /[0-9a-f]{64}/) != nil)
    // The same concept, made separately, has the same ID; another concept another.
    #expect(HealthEncoder.conceptID(try conceptIdentifier("synthetic-a")) == id)
    #expect(try conceptIdentifier("synthetic-a") == a)
    #expect(HealthEncoder.conceptID(try conceptIdentifier("synthetic-b")) != id)
  }

  @Test
  func medicationDosesArePagedThroughWithAnchorsAndMedicationsArent() {
    let types = HealthBackfillType.all(availableOn: .ios(26))
    let doses = types.first { $0.id == "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent" }
    #expect(doses?.entity == "health_medication_dose")
    #expect(doses?.pageSize == nil)
    // Read whole each run instead, like vision prescriptions.
    #expect(!types.contains { $0.id == "HKDataTypeUserAnnotatedMedicationConcept" })
  }

  @Test
  func workoutsAreBackfilledAndDeletedAsWorkouts() {
    let types = HealthBackfillType.all(availableOn: .ios(26))
    let workout = types.first { $0.id == "HKWorkoutTypeIdentifier" }
    #expect(workout?.entity == "health_workout")
    #expect(types.first { $0.id == "HKQuantityTypeIdentifierStepCount" }?.entity == "health_sample")
    #expect(types.first { $0.isCorrelation }?.entity == "health_correlation")
    #expect(types.first { $0.id == "HKDataTypeStateOfMind" }?.entity == "health_state_of_mind")
    #expect(
      types.first { $0.id == "HKScoredAssessmentTypeIdentifierPHQ9" }?.entity
        == "health_scored_assessment")
    #expect(types.first { $0.id == "HKDataTypeIdentifierAudiogram" }?.entity == "health_audiogram")
    let ecg = types.first { $0.id == "HKDataTypeIdentifierElectrocardiogram" }
    #expect(ecg?.entity == "health_electrocardiogram")
    // Its voltages are blobs, so it reads small pages.
    #expect(ecg?.pageSize == 50)
    let heartbeats = types.first { $0.id == "HKDataTypeIdentifierHeartbeatSeries" }
    #expect(heartbeats?.entity == "health_heartbeat_series")
    #expect(heartbeats?.pageSize == 200)
    let routes = types.first { $0.id == "HKWorkoutRouteTypeIdentifier" }
    #expect(routes?.entity == "health_workout_route")
    #expect(routes?.pageSize == 10)
    #expect(types.first { $0.id == "HKQuantityTypeIdentifierStepCount" }?.pageSize == nil)
  }

  @Test
  func workoutRouteWithItsLocationsBlob() throws {
    // A synthetic route, nowhere in particular (AGENTS.md).
    let locations = [
      WorkoutRouteRecord.Location(
        timestamp: start, latitude: 1.5, longitude: -2.25, altitude: 12, horizontalAccuracy: 4,
        verticalAccuracy: 3, speed: 2.5, course: 90),
      WorkoutRouteRecord.Location(
        timestamp: start.addingTimeInterval(1), latitude: 1.50001, longitude: -2.25001,
        altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: -1, speed: -1, course: -1),
    ]
    let route = WorkoutRouteRecord(
      id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000D1")!,
      workout: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000A1")!, locations: locations,
      provenance: HealthEncoder.provenance(
        of: HKQuantitySample(
          type: HKQuantityType(.heartRate),
          quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 1),
          start: start, end: start.addingTimeInterval(1))))

    let (mutation, blob) = HealthEncoder.workoutRoute(route)
    #expect(mutation.entity == "health_workout_route")
    let bytes = try #require(blob)
    #expect(bytes.count == 2 * HealthEncoder.locationBytes)
    func double(at offset: Int) -> Double {
      Double(bitPattern: bytes[offset..<offset + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) })
    }
    func float(at offset: Int) -> Float {
      Float(bitPattern: bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) })
    }
    #expect(double(at: 0) == start.timeIntervalSince1970)
    #expect(double(at: 8) == 1.5)
    #expect(double(at: 16) == -2.25)
    #expect(
      [float(at: 24), float(at: 28), float(at: 32), float(at: 36), float(at: 40)] == [
        12, 4, 3, 2.5, 90,
      ])
    // The second location's unknowns stay negative.
    #expect(float(at: 44 + 32) == -1)
    let decoded = try row(mutation, as: Components.Schemas.HealthWorkoutRoute.self)
    #expect(decoded.workout == "6f1c2a40-0000-4000-8000-0000000000a1")
    #expect(decoded.locationCount == 2)
    #expect(decoded.locations == HealthBlob.sha256(bytes))

    // A route without locations has no blob.
    let (emptyMutation, emptyBlob) = HealthEncoder.workoutRoute(
      WorkoutRouteRecord(id: route.id, workout: nil, locations: [], provenance: route.provenance))
    #expect(emptyBlob == nil)
    let emptyRow = try row(emptyMutation, as: Components.Schemas.HealthWorkoutRoute.self)
    #expect(emptyRow.locations == nil)
    #expect(emptyRow.locationCount == 0)
    #expect(emptyRow.workout == nil)
  }

  @Test
  func heartbeatSeriesWithItsBeatsAndGaps() throws {
    // Synthetic beats (AGENTS.md): one gap, before the fourth.
    let series = HeartbeatSeriesRecord(
      id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000F1")!,
      beats: [0, 0.82, 1.65, 3.31], gaps: [3],
      provenance: HealthEncoder.provenance(
        of: HKQuantitySample(
          type: HKQuantityType(.heartRate),
          quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 1),
          start: start, end: start.addingTimeInterval(60))))

    let mutation = HealthEncoder.heartbeatSeries(series)
    #expect(mutation.entity == "health_heartbeat_series")
    #expect(mutation.id == "6f1c2a40-0000-4000-8000-0000000000f1")
    let decoded = try row(mutation, as: Components.Schemas.HealthHeartbeatSeries.self)
    #expect(decoded.startDate == 1_760_400_000_000)
    #expect(decoded.endDate == 1_760_400_060_000)
    let encoded = try line(mutation)
    let row = try #require(encoded["row"] as? [String: Any])
    #expect(row["beats"] as? [Double] == [0, 0.82, 1.65, 3.31])
    #expect(row["gaps"] as? [Int] == [3])

    // Rounded to 0.1 ms, so a long series stays within a batch line.
    var precise = series
    precise.beats = [0.123456789]
    let rounded = try #require(
      try line(HealthEncoder.heartbeatSeries(precise))["row"] as? [String: Any])
    #expect(rounded["beats"] as? [Double] == [0.1235])
  }

  @Test
  func electrocardiogramWithItsVoltagesBlob() throws {
    // Synthetic voltages, as an Apple Watch would record them at 512 Hz (AGENTS.md).
    let microvolts: [Float] = [0, 12.5, -40.25, 980, .nan]
    let ecg = ElectrocardiogramRecord(
      id: UUID(uuidString: "6F1C2A40-0000-4000-8000-0000000000E1")!,
      classification: HKElectrocardiogram.Classification.sinusRhythm.rawValue,
      symptomsStatus: HKElectrocardiogram.SymptomsStatus.none.rawValue, averageHeartRate: 62,
      samplingFrequency: 512, microvolts: microvolts,
      provenance: HealthEncoder.provenance(
        of: HKQuantitySample(
          type: HKQuantityType(.heartRate),
          quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 1),
          start: start, end: start.addingTimeInterval(30))))

    let (mutation, blob) = HealthEncoder.electrocardiogram(ecg)
    #expect(mutation.entity == "health_electrocardiogram")
    #expect(mutation.id == "6f1c2a40-0000-4000-8000-0000000000e1")
    // One little-endian float per measurement.
    let voltages = try #require(blob)
    #expect(voltages.count == 20)
    #expect(Array(voltages.prefix(8)) == [0, 0, 0, 0, 0x00, 0x00, 0x48, 0x41])
    let decodedVoltages = stride(from: 0, to: voltages.count, by: 4).map { offset in
      Float(
        bitPattern: voltages[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) })
    }
    #expect(Array(decodedVoltages.prefix(4)) == Array(microvolts.prefix(4)))
    #expect(decodedVoltages[4].isNaN)
    // It's what the server's schema accepts, referring to the blob by its hash.
    let decoded = try row(mutation, as: Components.Schemas.HealthElectrocardiogram.self)
    #expect(decoded.classification == 1)
    #expect(decoded.symptomsStatus == 1)
    #expect(decoded.averageHeartRate == 62)
    #expect(decoded.samplingFrequency == 512)
    #expect(decoded.voltageCount == 5)
    #expect(decoded.voltages == HealthBlob.sha256(voltages))
    #expect(decoded.startDate == 1_760_400_000_000)

    // A recording without measurements has no blob.
    var empty = ecg
    empty.microvolts = []
    empty.averageHeartRate = nil
    let (emptyMutation, emptyBlob) = HealthEncoder.electrocardiogram(empty)
    #expect(emptyBlob == nil)
    let emptyRow = try row(emptyMutation, as: Components.Schemas.HealthElectrocardiogram.self)
    #expect(emptyRow.voltages == nil)
    #expect(emptyRow.voltageCount == 0)
    #expect(emptyRow.averageHeartRate == nil)
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
  func cutsFilesByCount() throws {
    var writer = HealthBatchWriter(maxRecords: 2)
    var files: [Data] = []
    for _ in 0..<5 {
      if let file = try writer.append(mutation(10)) { files.append(file) }
    }
    if let file = try writer.finish() { files.append(file) }
    let counts = try files.map {
      try String(decoding: Gzip.decompress($0), as: UTF8.self).split(separator: "\n").count
    }
    #expect(counts == [2, 2, 1])
  }

  @Test
  func sendsEachFilesSourceRevisionsAndDevicesOnce() throws {
    // Synthetic data only (AGENTS.md).
    let sample = { (n: Int, watch: Bool) -> HealthMutation in
      .upsert(
        "health_sample", id: "6f1c2a40-0000-4000-8000-00000000000\(n)",
        row: [
          "type": "HKQuantityTypeIdentifierStepCount", "value": .number(Double(n)),
          "sourceRevision": .object(["version": .string(watch ? "11.0" : "26.0")]),
          "device": watch ? .object(["name": "Apple Watch"]) : .null,
        ])
    }
    var writer = HealthBatchWriter(maxRecords: 3)
    var files: [Data] = []
    for (n, watch) in [(1, true), (2, false), (3, true), (4, true)] {
      if let file = try writer.append(sample(n, watch)) { files.append(file) }
    }
    if let file = try writer.finish() { files.append(file) }
    let lines = try files.map { file in
      try String(decoding: Gzip.decompress(file), as: UTF8.self).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
      }
    }
    // Three samples a file, each file with the provenance records its samples refer to, first.
    #expect(
      lines.map { $0.map { $0["entity"] as! String } } == [
        [
          "health_provenance", "health_sample", "health_provenance", "health_sample",
          "health_sample",
        ],
        ["health_provenance", "health_sample"],
      ])
    let watch = try #require(lines[0][0]["id"] as? String)
    let phone = try #require(lines[0][2]["id"] as? String)
    #expect(watch.count == 32 && watch != phone)
    #expect(lines[1][0]["id"] as? String == watch)
    let watchRow = try #require(lines[0][0]["row"] as? [String: Any])
    #expect(watchRow["device"] as? [String: String] == ["name": "Apple Watch"])
    #expect(watchRow["sourceRevision"] as? [String: String] == ["version": "11.0"])
    let phoneRow = try #require(lines[0][2]["row"] as? [String: Any])
    #expect(phoneRow["device"] is NSNull)
    let sampleRow = try #require(lines[0][1]["row"] as? [String: Any])
    #expect(sampleRow["provenance"] as? String == watch)
    #expect(sampleRow["device"] is NSNull && sampleRow["sourceRevision"] is NSNull)
    #expect(sampleRow["value"] as? Double == 1)
  }

  @Test
  func anUpsertWithoutASourceRevisionOrDeviceKeepsTheStoredOnes() throws {
    var writer = HealthBatchWriter()
    let partial = HealthMutation.upsert(
      "health_sample", id: "6f1c2a40-0000-4000-8000-000000000001", row: ["value": 2])
    _ = try writer.append(partial)
    let file = try #require(try writer.finish())
    let lines = String(decoding: try Gzip.decompress(file), as: UTF8.self).split(separator: "\n")
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    let row = try #require(
      (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["row"]
        as? [String: Any])
    #expect(Set(row.keys) == ["value"])
  }

  @Test
  func aRecordWhoseDeviceIsTooLongIsNamed() throws {
    var writer = HealthBatchWriter()
    let sample = HealthMutation.upsert(
      "health_sample", id: "6f1c2a40-0000-4000-8000-000000000001",
      row: [
        "device": .object([
          "name": .string(String(repeating: "x", count: HealthBatchWriter.maxLineBytes))
        ])
      ])
    #expect(
      throws: HealthBatchWriter.LineTooLong(
        entity: "health_sample", id: "6f1c2a40-0000-4000-8000-000000000001")
    ) {
      try writer.append(sample)
    }
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
