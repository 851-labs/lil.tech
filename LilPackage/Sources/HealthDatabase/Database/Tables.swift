public import Foundation
public import SQLiteData

// Local copies of the server's health entities (`Services/api/src/health/HealthEntities.ts`).
// Times are Unix milliseconds, as on the server. JSON fields are stored as JSON text.

/// A quantity or category sample, keyed by HealthKit's UUID.
@Table
public struct HealthSample: Equatable, Identifiable, Sendable {
  public let id: String
  /// The HealthKit type identifier, e.g. `HKQuantityTypeIdentifierStepCount`.
  public var type: String
  public var startDate: Int
  public var endDate: Int
  /// A quantity sample's value, in `unit`.
  public var value: Double?
  public var unit: String?
  /// A category sample's value (`HKCategoryValue…`).
  public var categoryValue: Int?
  public var correlationID: String?
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, type: String, startDate: Int, endDate: Int, value: Double? = nil,
    unit: String? = nil, categoryValue: Int? = nil, correlationID: String? = nil,
    sourceName: String, sourceBundleID: String, sourceRevision: String? = nil,
    device: String? = nil, metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
    self.value = value
    self.unit = unit
    self.categoryValue = categoryValue
    self.correlationID = correlationID
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }

  public var start: Date { Date(unixMilliseconds: startDate) }
  public var end: Date { Date(unixMilliseconds: endDate) }
}

/// A blood pressure or food correlation. Its samples point at it with `correlationID`.
@Table
public struct HealthCorrelation: Equatable, Identifiable, Sendable {
  public let id: String
  public var type: String
  public var startDate: Int
  public var endDate: Int
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, type: String, startDate: Int, endDate: Int, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A characteristic (date of birth, blood type…), keyed by its type identifier.
@Table
public struct HealthCharacteristic: Equatable, Identifiable, Sendable {
  public let id: String
  /// JSON, e.g. `{"day":2,"month":4,"year":1990}` or an enum case's name.
  public var value: String

  public init(id: String, value: String) {
    self.id = id
    self.value = value
  }
}

/// A workout (`health_workout`). Its activities, events and statistics are JSON text, as the
/// server documents them (`HealthWorkout` in `Services/api/src/health/HealthEntities.ts`).
@Table
public struct HealthWorkout: Equatable, Identifiable, Sendable {
  public let id: String
  /// `HKWorkoutActivityType`'s raw value.
  public var activityType: Int
  public var startDate: Int
  public var endDate: Int
  /// Seconds of activity, excluding pauses.
  public var duration: Double
  public var activities: String
  public var events: String
  public var statistics: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, activityType: Int, startDate: Int, endDate: Int, duration: Double,
    activities: String, events: String, statistics: String, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.activityType = activityType
    self.startDate = startDate
    self.endDate = endDate
    self.duration = duration
    self.activities = activities
    self.events = events
    self.statistics = statistics
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A State of Mind log (`health_state_of_mind`). Labels and associations are JSON arrays of
/// HealthKit raw values.
@Table
public struct HealthStateOfMind: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  /// 1 a momentary emotion, 2 a daily mood.
  public var kind: Int
  /// From -1 (very unpleasant) to 1 (very pleasant).
  public var valence: Double
  public var valenceClassification: Int
  public var labels: String
  public var associations: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, kind: Int, valence: Double,
    valenceClassification: Int, labels: String, associations: String, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.kind = kind
    self.valence = valence
    self.valenceClassification = valenceClassification
    self.labels = labels
    self.associations = associations
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A GAD-7 or PHQ-9 assessment (`health_scored_assessment`). Answers are a JSON array of
/// HealthKit raw values, in question order.
@Table
public struct HealthScoredAssessment: Equatable, Identifiable, Sendable {
  public let id: String
  /// The type identifier, e.g. `HKScoredAssessmentTypeIdentifierGAD7`.
  public var type: String
  public var startDate: Int
  public var endDate: Int
  public var score: Int
  public var risk: Int
  public var answers: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, type: String, startDate: Int, endDate: Int, score: Int, risk: Int,
    answers: String, sourceName: String, sourceBundleID: String, sourceRevision: String? = nil,
    device: String? = nil, metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
    self.score = score
    self.risk = risk
    self.answers = answers
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// An audiogram (`health_audiogram`). `points` is JSON, as the server documents it.
@Table
public struct HealthAudiogram: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  public var points: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, points: String, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.points = points
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A glasses or contacts prescription (`health_vision_prescription`, 851-2572). Its start and end
/// are the date it was issued; `rightEye` and `leftEye` are JSON, as the server documents them.
@Table
public struct HealthVisionPrescription: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  /// `HKVisionPrescriptionType`'s raw value: 1 glasses, 2 contacts.
  public var prescriptionType: Int
  public var expirationDate: Int?
  public var brand: String?
  public var rightEye: String?
  public var leftEye: String?
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, prescriptionType: Int, expirationDate: Int? = nil,
    brand: String? = nil, rightEye: String? = nil, leftEye: String? = nil, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.prescriptionType = prescriptionType
    self.expirationDate = expirationDate
    self.brand = brand
    self.rightEye = rightEye
    self.leftEye = leftEye
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A Health Document (`health_document`, 851-2836): a clinical document (CDA) the person shares.
/// `xml` is its blob's SHA-256, downloaded when it's shown. The title and names are what HealthKit
/// extracted from the XML, possibly empty.
@Table
public struct HealthDocument: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  public var title: String
  public var patientName: String
  public var authorName: String
  public var custodianName: String
  public var xml: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, title: String, patientName: String,
    authorName: String, custodianName: String, xml: String, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.title = title
    self.patientName = patientName
    self.authorName = authorName
    self.custodianName = custodianName
    self.xml = xml
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A medication the person shares (`health_medication`, 851-2571), keyed by its concept's ID,
/// which its doses refer to. `codings` is JSON, as the server documents it.
@Table
public struct HealthMedication: Equatable, Identifiable, Sendable {
  public let id: String
  /// Its name, as Health shows it.
  public var name: String
  /// The name the person gave it, if any.
  public var nickname: String?
  /// `HKMedicationGeneralForm`'s raw value, e.g. `tablet`.
  public var generalForm: String
  public var isArchived: Bool
  public var hasSchedule: Bool
  public var codings: String

  public init(
    id: String, name: String, nickname: String? = nil, generalForm: String,
    isArchived: Bool = false, hasSchedule: Bool = false, codings: String = "[]"
  ) {
    self.id = id
    self.name = name
    self.nickname = nickname
    self.generalForm = generalForm
    self.isArchived = isArchived
    self.hasSchedule = hasSchedule
    self.codings = codings
  }
}

/// A medication dose event (`health_medication_dose`, 851-2571): taken, skipped, or a scheduled
/// dose that wasn't logged.
@Table
public struct HealthMedicationDose: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  /// The ``HealthMedication`` it's a dose of.
  public var medication: String
  /// `HKMedicationDoseEvent.LogStatus`'s raw value, e.g. 4 taken, 5 skipped.
  public var logStatus: Int
  /// `HKMedicationDoseEvent.ScheduleType`'s raw value: 1 as needed, 2 scheduled.
  public var scheduleType: Int
  public var scheduledDate: Int?
  public var scheduledDoseQuantity: Double?
  public var doseQuantity: Double?
  /// The quantities' unit, as an `HKUnit` string.
  public var unit: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, medication: String, logStatus: Int,
    scheduleType: Int, scheduledDate: Int? = nil, scheduledDoseQuantity: Double? = nil,
    doseQuantity: Double? = nil, unit: String, sourceName: String, sourceBundleID: String,
    sourceRevision: String? = nil, device: String? = nil, metadata: String? = nil,
    provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.medication = medication
    self.logStatus = logStatus
    self.scheduleType = scheduleType
    self.scheduledDate = scheduledDate
    self.scheduledDoseQuantity = scheduledDoseQuantity
    self.doseQuantity = doseQuantity
    self.unit = unit
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// The Activity rings for one day, keyed by the day (`YYYY-MM-DD` in the iPhone's calendar).
@Table
public struct HealthActivitySummary: Equatable, Identifiable, Sendable {
  public let id: String
  public var activeEnergyBurned: Double?
  public var activeEnergyBurnedGoal: Double?
  public var appleMoveTime: Double?
  public var appleMoveTimeGoal: Double?
  public var appleExerciseTime: Double?
  public var appleExerciseTimeGoal: Double?
  public var appleStandHours: Double?
  public var appleStandHoursGoal: Double?
  public var activityMoveMode: String?
  public var paused: Bool?

  public init(
    id: String, activeEnergyBurned: Double? = nil, activeEnergyBurnedGoal: Double? = nil,
    appleMoveTime: Double? = nil, appleMoveTimeGoal: Double? = nil,
    appleExerciseTime: Double? = nil, appleExerciseTimeGoal: Double? = nil,
    appleStandHours: Double? = nil, appleStandHoursGoal: Double? = nil,
    activityMoveMode: String? = nil, paused: Bool? = nil
  ) {
    self.id = id
    self.activeEnergyBurned = activeEnergyBurned
    self.activeEnergyBurnedGoal = activeEnergyBurnedGoal
    self.appleMoveTime = appleMoveTime
    self.appleMoveTimeGoal = appleMoveTimeGoal
    self.appleExerciseTime = appleExerciseTime
    self.appleExerciseTimeGoal = appleExerciseTimeGoal
    self.appleStandHours = appleStandHours
    self.appleStandHoursGoal = appleStandHoursGoal
    self.activityMoveMode = activityMoveMode
    self.paused = paused
  }
}

/// A cumulative type's sum over one 30-minute bucket, as one iPhone's HealthKit computed it.
@Table
public struct HealthStatistic: Equatable, Identifiable, Sendable {
  /// `<device>/<type>@<bucketStart>`.
  public let id: String
  public var device: String
  public var type: String
  public var bucketStart: Int
  public var sum: Double
  public var unit: String

  public init(id: String, device: String, type: String, bucketStart: Int, sum: Double, unit: String)
  {
    self.id = id
    self.device = device
    self.type = type
    self.bucketStart = bucketStart
    self.sum = sum
    self.unit = unit
  }
}

/// One iPhone's statistics status, keyed by its device ID.
@Table
public struct HealthStatisticsDevice: Equatable, Identifiable, Sendable {
  public let id: String
  public var device: String
  public var pairedWithWatch: Bool
  /// When the server last applied its report.
  public var reportedAt: Int

  public init(id: String, device: String, pairedWithWatch: Bool, reportedAt: Int) {
    self.id = id
    self.device = device
    self.pairedWithWatch = pairedWithWatch
    self.reportedAt = reportedAt
  }
}

extension Date {
  public init(unixMilliseconds: Int) {
    self.init(timeIntervalSince1970: Double(unixMilliseconds) / 1000)
  }

  public var unixMilliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}

/// An ECG recording (`health_electrocardiogram`). `voltages` is its blob's SHA-256 (the server's
/// `HealthElectrocardiogram` documents the format), downloaded when it's shown.
@Table
public struct HealthElectrocardiogram: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  public var classification: Int
  public var symptomsStatus: Int
  public var averageHeartRate: Double?
  public var samplingFrequency: Double?
  public var voltageCount: Int
  public var voltages: String?
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, classification: Int, symptomsStatus: Int,
    averageHeartRate: Double?, samplingFrequency: Double?, voltageCount: Int, voltages: String?,
    sourceName: String, sourceBundleID: String, sourceRevision: String? = nil,
    device: String? = nil, metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.classification = classification
    self.symptomsStatus = symptomsStatus
    self.averageHeartRate = averageHeartRate
    self.samplingFrequency = samplingFrequency
    self.voltageCount = voltageCount
    self.voltages = voltages
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A heartbeat series (`health_heartbeat_series`). `beats` and `gaps` are JSON, as the server
/// documents them.
@Table("healthHeartbeatSeries")
public struct HealthHeartbeatSeries: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  public var beats: String
  public var gaps: String
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, beats: String, gaps: String, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.beats = beats
    self.gaps = gaps
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A workout route (`health_workout_route`). `locations` is its blob's SHA-256 (the server's
/// `HealthWorkoutRoute` documents the format), downloaded when it's shown.
@Table
public struct HealthWorkoutRoute: Equatable, Identifiable, Sendable {
  public let id: String
  public var startDate: Int
  public var endDate: Int
  /// The workout's ID, if HealthKit linked one.
  public var workout: String?
  public var locationCount: Int
  public var locations: String?
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?
  /// The ``HealthProvenance`` with its source revision and device, from iPhones that send them
  /// once (851-2674). Otherwise they're in `sourceRevision` and `device`.
  public var provenance: String?

  public init(
    id: String, startDate: Int, endDate: Int, workout: String?, locationCount: Int,
    locations: String?,
    sourceName: String, sourceBundleID: String, sourceRevision: String? = nil,
    device: String? = nil, metadata: String? = nil, provenance: String? = nil
  ) {
    self.id = id
    self.startDate = startDate
    self.endDate = endDate
    self.workout = workout
    self.locationCount = locationCount
    self.locations = locations
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
    self.provenance = provenance
  }
}

/// A source revision and device that samples share (851-2674), keyed by a hash of the two.
@Table
public struct HealthProvenance: Equatable, Identifiable, Sendable {
  public let id: String
  /// `HKSourceRevision` as JSON text.
  public var sourceRevision: String?
  /// `HKDevice` as JSON text.
  public var device: String?

  public init(id: String, sourceRevision: String? = nil, device: String? = nil) {
    self.id = id
    self.sourceRevision = sourceRevision
    self.device = device
  }
}

/// A data type pinned to Summary (851-2641), keyed by its type ID. Synced, so every Mac shows the
/// same pins; the Mac writes them through ``SyncClient/push``.
@Table
public struct HealthPin: Equatable, Identifiable, Sendable {
  public let id: String
  /// Pins are shown by position, lowest first.
  public var position: Double

  public init(id: String, position: Double) {
    self.id = id
    self.position = position
  }
}
