public import Foundation
import HealthCatalog
public import SQLiteData

/// A database with two weeks of synthetic health data across every category, for previews
/// (AGENTS.md). Values are made up but plausible for each type's unit, and the same for the same
/// `now`.
public func makePreviewHealthDatabase(
  now: Date = .now, calendar: Calendar = .current
) -> any DatabaseWriter {
  do {
    let database = try HealthDatabase.make()
    try database.write { db in try PreviewData(now: now, calendar: calendar).insert(db) }
    return database
  } catch {
    fatalError("Couldn't make the preview health database: \(error)")
  }
}

/// The iPhone the preview data comes from.
let previewDevice = "dev_000000000000000000000000ph"

private struct PreviewData {
  let now: Date
  let calendar: Calendar
  let days = 14

  /// Midnight of each day, oldest first, ending today.
  var dayStarts: [Date] {
    let today = calendar.startOfDay(for: now)
    return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
  }

  func insert(_ db: Database) throws {
    try HealthStatisticsDevice.insert {
      HealthStatisticsDevice(
        id: previewDevice, device: previewDevice, pairedWithWatch: true,
        reportedAt: now.unixMilliseconds)
    }
    .execute(db)

    for type in HealthCatalog.all {
      var random = SplitMix64(seed: type.id)
      switch type.kind {
      case .quantity where type.aggregation?.isCumulative == true:
        try insertStatistics(of: type, &random, db)
      case .quantity:
        try insertSamples(of: type, &random, db)
      case .category:
        try insertCategorySamples(of: type, &random, db)
      default:
        break
      }
    }
    try insertBloodPressure(db)
    try insertWorkouts(db)
    try insertCharacteristics(db)
    try insertVisionPrescriptions(db)
    try insertMedications(db)
    try insertActivitySummaries(db)
  }

  /// 30-minute sums from 7:00 to 23:00, plus a few raw samples a day.
  private func insertStatistics(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    let unit = type.unit ?? "count"
    let (low, high) = Self.range(for: type, perBucket: true)
    var statistics: [HealthStatistic] = []
    var samples: [HealthSample] = []
    for day in dayStarts {
      for halfHour in 14..<46 {
        // On UTC half-hours, like the server's buckets, even in :45 time zones.
        let local = day.addingTimeInterval(Double(halfHour) * 1800).timeIntervalSince1970
        let start = Date(timeIntervalSince1970: (local / 1800).rounded(.down) * 1800)
        guard start < now else { break }
        let sum = random.next(in: low...high)
        statistics.append(
          HealthStatistic(
            id: "\(previewDevice)/\(type.id)@\(start.unixMilliseconds)", device: previewDevice,
            type: type.id, bucketStart: start.unixMilliseconds, sum: sum, unit: unit))
        if halfHour.isMultiple(of: 12) {
          samples.append(
            sample(type, start: start, minutes: 10, value: sum / 3, unit: unit, &random))
        }
      }
    }
    try HealthStatistic.insert { statistics }.execute(db)
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// Every 30 minutes for heart rate, otherwise twice a day.
  private func insertSamples(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    let unit = type.unit ?? "count"
    let (low, high) = Self.range(for: type, perBucket: false)
    let hours: [Double] =
      type.id == "HKQuantityTypeIdentifierHeartRate"
      ? stride(from: 0, to: 24, by: 0.5).map(\.self) : [8, 20]
    var samples: [HealthSample] = []
    for day in dayStarts {
      for hour in hours {
        let start = day.addingTimeInterval(hour * 3600)
        guard start < now else { break }
        samples.append(
          sample(
            type, start: start, minutes: 1, value: random.next(in: low...high), unit: unit,
            &random))
      }
    }
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// Sleep stages every night, stand hours every day, and other events every few days.
  private func insertCategorySamples(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    var samples: [HealthSample] = []
    for (index, day) in dayStarts.enumerated() {
      switch type.id {
      case "HKCategoryTypeIdentifierSleepAnalysis":
        // In bed from 23:00, cycling through core (3), deep (4), REM (5) and awake (2).
        let bedtime = day.addingTimeInterval(-3600)
        var start = bedtime
        for stage in [3, 4, 3, 5, 3, 4, 5, 2, 3, 5] {
          let minutes = random.next(in: 25...60)
          guard start < now else { break }
          samples.append(
            sample(type, start: start, minutes: minutes, categoryValue: stage, &random))
          start = start.addingTimeInterval(minutes * 60)
        }
        // In bed (0) from a little before falling asleep to a little after waking.
        let inBed = bedtime.addingTimeInterval(-15 * 60)
        // Not past now, for tonight's night.
        let outOfBed = min(start.addingTimeInterval(10 * 60), now)
        if outOfBed > inBed {
          samples.append(
            sample(
              type, start: inBed, minutes: outOfBed.timeIntervalSince(inBed) / 60, categoryValue: 0,
              &random))
        }
      case "HKCategoryTypeIdentifierAppleStandHour":
        for hour in 8..<21 {
          let start = day.addingTimeInterval(Double(hour) * 3600)
          guard start < now else { break }
          let stood = random.next(in: 0...1) < 0.8 ? 0 : 1
          samples.append(sample(type, start: start, minutes: 60, categoryValue: stood, &random))
        }
      default:
        guard index.isMultiple(of: 3) else { continue }
        let start = day.addingTimeInterval(14 * 3600)
        guard start < now else { continue }
        samples.append(sample(type, start: start, minutes: 30, categoryValue: 0, &random))
      }
    }
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// A run, a walk or a strength workout most days, with their statistics, and segments for
  /// the runs. Routes are left out: their locations are blobs, which previews pass directly.
  private func insertWorkouts(_ db: Database) throws {
    var random = SplitMix64(seed: "HKWorkoutTypeIdentifier")
    var workouts: [HealthWorkout] = []
    for (index, day) in dayStarts.enumerated() {
      let kind = index % 3
      let start = day.addingTimeInterval((kind == 2 ? 18 : 7) * 3600)
      guard start < now else { continue }
      let minutes = random.next(in: 25...55)
      let activityType = [37, 52, 50][kind]
      let distance = kind == 2 ? nil : minutes * (kind == 0 ? 170 : 90)
      let energy = minutes * (kind == 0 ? 11 : kind == 1 ? 5 : 7)
      let heartRate = kind == 0 ? 152.0 : kind == 1 ? 104 : 121
      var statistics =
        #""HKQuantityTypeIdentifierActiveEnergyBurned":{"unit":"kcal","sum":\#(energy)},"HKQuantityTypeIdentifierHeartRate":{"unit":"count/min","average":\#(heartRate),"minimum":\#(heartRate - 30),"maximum":\#(heartRate + 22)}"#
      if let distance {
        statistics +=
          #","HKQuantityTypeIdentifierDistanceWalkingRunning":{"unit":"m","sum":\#(distance)}"#
      }
      let startMS = start.unixMilliseconds
      let segments =
        kind == 0
        ? (0..<3).map { segment in
          let from = startMS + segment * Int(minutes * 20_000)
          return #"{"type":7,"startDate":\#(from),"endDate":\#(from + Int(minutes * 20_000))}"#
        }
        .joined(separator: ",") : ""
      workouts.append(
        HealthWorkout(
          id: random.uuid(), activityType: activityType, startDate: startMS,
          endDate: start.addingTimeInterval(minutes * 60 + 90).unixMilliseconds,
          duration: minutes * 60, activities: "[]", events: "[\(segments)]",
          statistics: "{\(statistics)}", sourceName: "Apple Watch",
          sourceBundleID: "com.apple.health.watch", device: Self.watch))
    }
    if !workouts.isEmpty { try HealthWorkout.insert { workouts }.execute(db) }
  }

  /// A blood pressure reading every other morning.
  private func insertBloodPressure(_ db: Database) throws {
    var random = SplitMix64(seed: "HKCorrelationTypeIdentifierBloodPressure")
    for (index, day) in dayStarts.enumerated() where index.isMultiple(of: 2) {
      let start = day.addingTimeInterval(7.5 * 3600)
      guard start < now else { continue }
      let correlation = random.uuid()
      try HealthCorrelation.insert {
        HealthCorrelation(
          id: correlation, type: "HKCorrelationTypeIdentifierBloodPressure",
          startDate: start.unixMilliseconds, endDate: start.unixMilliseconds,
          sourceName: "Blood Pressure Monitor", sourceBundleID: "com.example.bloodpressure")
      }
      .execute(db)
      for (id, range) in [("Systolic", 112.0...128.0), ("Diastolic", 70.0...84.0)] {
        guard let type = HealthCatalog.type(id: "HKQuantityTypeIdentifierBloodPressure\(id)")
        else { continue }
        var reading = sample(
          type, start: start, minutes: 0, value: random.next(in: range).rounded(), unit: "mmHg",
          &random)
        reading.correlationID = correlation
        reading.sourceName = "Blood Pressure Monitor"
        try HealthSample.insert { reading }.execute(db)
      }
    }
  }

  private func insertCharacteristics(_ db: Database) throws {
    try HealthCharacteristic.insert {
      HealthCharacteristic(
        id: "HKCharacteristicTypeIdentifierDateOfBirth", value: #"{"day":2,"month":4,"year":1990}"#)
      HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBiologicalSex", value: #""female""#)
      HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBloodType", value: #""aPositive""#)
    }
    .execute(db)
  }

  /// Current glasses, and contacts that have expired.
  private func insertVisionPrescriptions(_ db: Database) throws {
    let day = 86_400.0
    let glassesIssued = calendar.startOfDay(for: now).addingTimeInterval(-120 * day)
    let contactsIssued = calendar.startOfDay(for: now).addingTimeInterval(-800 * day)
    try HealthVisionPrescription.insert {
      HealthVisionPrescription(
        id: "3d2b6a10-0000-4000-8000-000000000001", startDate: glassesIssued.unixMilliseconds,
        endDate: glassesIssued.unixMilliseconds, prescriptionType: 1,
        expirationDate: glassesIssued.addingTimeInterval(730 * day).unixMilliseconds,
        rightEye:
          #"{"sphere":-1.75,"cylinder":-0.5,"axis":90,"addPower":null,"vertexDistance":12,"farPupillaryDistance":31.5,"nearPupillaryDistance":29.5,"prism":null}"#,
        leftEye:
          #"{"sphere":-2.25,"cylinder":-0.75,"axis":85,"addPower":null,"vertexDistance":12,"farPupillaryDistance":32,"nearPupillaryDistance":30,"prism":null}"#,
        sourceName: "Health", sourceBundleID: "com.apple.Health")
      HealthVisionPrescription(
        id: "3d2b6a10-0000-4000-8000-000000000002", startDate: contactsIssued.unixMilliseconds,
        endDate: contactsIssued.unixMilliseconds, prescriptionType: 2,
        expirationDate: contactsIssued.addingTimeInterval(365 * day).unixMilliseconds,
        brand: "Daily Comfort",
        rightEye:
          #"{"sphere":-1.5,"cylinder":null,"axis":null,"addPower":null,"baseCurve":8.6,"diameter":14.2}"#,
        leftEye:
          #"{"sphere":-2,"cylinder":null,"axis":null,"addPower":null,"baseCurve":8.6,"diameter":14.2}"#,
        sourceName: "Health", sourceBundleID: "com.apple.Health")
    }
    .execute(db)
  }

  /// A tablet scheduled morning and evening, mostly taken; a spray taken as needed; and an
  /// archived capsule. Made-up names.
  private func insertMedications(_ db: Database) throws {
    let tablet = String(repeating: "a", count: 64)
    let spray = String(repeating: "b", count: 64)
    try HealthMedication.insert {
      HealthMedication(
        id: tablet, name: "Synthetic Tablet A 10 mg", nickname: "Morning Tablet",
        generalForm: "tablet", hasSchedule: true)
      HealthMedication(id: spray, name: "Synthetic Spray B", generalForm: "spray")
      HealthMedication(
        id: String(repeating: "c", count: 64), name: "Synthetic Capsule C",
        generalForm: "capsule", isArchived: true, hasSchedule: true)
    }
    .execute(db)
    var random = SplitMix64(seed: "HKMedicationDoseEvent")
    var doses: [HealthMedicationDose] = []
    for (index, day) in dayStarts.enumerated() {
      for hour in [8.0, 20.0] {
        let due = day.addingTimeInterval(hour * 3600)
        guard due < now else { continue }
        // Taken a few minutes late, but skipped or left unanswered now and then.
        let roll = random.next(in: 0...1)
        let status = roll < 0.82 ? 4 : roll < 0.92 ? 5 : 1
        let logged = status == 4 ? due.addingTimeInterval(random.next(in: 0...40) * 60) : due
        doses.append(
          HealthMedicationDose(
            id: random.uuid(), startDate: logged.unixMilliseconds,
            endDate: logged.unixMilliseconds, medication: tablet, logStatus: status,
            scheduleType: 2, scheduledDate: due.unixMilliseconds, scheduledDoseQuantity: 1,
            doseQuantity: status == 4 ? 1 : nil, unit: "count", sourceName: "iPhone",
            sourceBundleID: "com.apple.Health"))
      }
      if index.isMultiple(of: 4) {
        let taken = day.addingTimeInterval(13.5 * 3600)
        guard taken < now else { continue }
        doses.append(
          HealthMedicationDose(
            id: random.uuid(), startDate: taken.unixMilliseconds, endDate: taken.unixMilliseconds,
            medication: spray, logStatus: 4, scheduleType: 1, doseQuantity: 2, unit: "count",
            sourceName: "iPhone", sourceBundleID: "com.apple.Health"))
      }
    }
    if !doses.isEmpty { try HealthMedicationDose.insert { doses }.execute(db) }
  }

  private func insertActivitySummaries(_ db: Database) throws {
    var random = SplitMix64(seed: "HKActivitySummary")
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let summaries = dayStarts.map { day in
      HealthActivitySummary(
        id: formatter.string(from: day),
        activeEnergyBurned: random.next(in: 280...720).rounded(), activeEnergyBurnedGoal: 500,
        appleMoveTime: nil, appleMoveTimeGoal: nil,
        appleExerciseTime: random.next(in: 10...60).rounded(), appleExerciseTimeGoal: 30,
        appleStandHours: random.next(in: 8...13).rounded(), appleStandHoursGoal: 12,
        activityMoveMode: "activeEnergy", paused: false)
    }
    try HealthActivitySummary.insert { summaries }.execute(db)
  }

  private func sample(
    _ type: HealthDataType, start: Date, minutes: Double, value: Double? = nil,
    unit: String? = nil, categoryValue: Int? = nil, _ random: inout SplitMix64
  ) -> HealthSample {
    let fromWatch = type.category == .heart || type.id.hasSuffix("SleepAnalysis")
    return HealthSample(
      id: random.uuid(), type: type.id, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, value: value, unit: unit,
      categoryValue: categoryValue,
      sourceName: fromWatch ? "Apple Watch" : "iPhone",
      sourceBundleID: fromWatch ? "com.apple.health.watch" : "com.apple.health.iphone",
      sourceRevision: fromWatch ? Self.watchRevision : Self.phoneRevision,
      device: fromWatch ? Self.watch : Self.phone,
      metadata: type.id == "HKQuantityTypeIdentifierHeartRate"
        ? #"{"HKMetadataKeyHeartRateMotionContext":1}"# : nil)
  }

  // Made-up devices, in the shape the iPhone uploads (`HealthEncoder.provenance`).
  static let watch =
    #"{"hardwareVersion":"Watch7,1","manufacturer":"Apple Inc.","model":"Watch","name":"Apple Watch","softwareVersion":"26.0"}"#
  static let phone =
    #"{"hardwareVersion":"iPhone17,1","manufacturer":"Apple Inc.","model":"iPhone","name":"iPhone","softwareVersion":"26.0"}"#
  static let watchRevision =
    #"{"operatingSystemVersion":"26.0.0","productType":"Watch7,1","version":"26.0"}"#
  static let phoneRevision =
    #"{"operatingSystemVersion":"26.0.0","productType":"iPhone17,1","version":"26.0"}"#

  /// Plausible values for a type: per sample, or per 30-minute bucket for cumulative types.
  static func range(for type: HealthDataType, perBucket: Bool) -> (Double, Double) {
    switch type.unit {
    case "count": perBucket ? (0, 400) : (1, 10)
    case "m": perBucket ? (0, 600) : (300, 600)
    case "kcal": perBucket ? (5, 40) : (100, 300)
    case "min": (0, 10)
    case "mg": (0, 60)
    case "mcg": (0, 20)
    case "g": (0, 30)
    case "IU": (0, 100)
    case "L", "mL": perBucket ? (0, 0.4) : (3, 5)
    case "%": (0.94, 0.99)
    case "count/min": (56, 110)
    case "m/s": (0.9, 1.5)
    case "degC": (36.3, 37.1)
    case "W": (100, 250)
    case "dBASPL": (55, 80)
    case "ms": (30, 80)
    case "kg": (70, 72)
    case "cm": (170, 171)
    case "mmHg": (70, 128)
    case "mg/dL": (80, 120)
    default: (1, 10)
    }
  }
}

/// A small seeded generator, so preview data is the same every time.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: String) {
    // FNV-1a, since `hashValue` changes between launches.
    state = seed.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
  }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  mutating func next(in range: ClosedRange<Double>) -> Double {
    Double.random(in: range, using: &self)
  }

  /// A lowercase UUID, like a HealthKit sample's.
  mutating func uuid() -> String {
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &self) }
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
  }
}
