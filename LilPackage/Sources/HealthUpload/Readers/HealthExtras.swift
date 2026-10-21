public import Dependencies
public import Foundation
import HealthKit
import IssueReporting

// What has no anchors: characteristics, vision prescriptions, Health Documents, medications and
// Activity summaries. The backfill reads them on every run of everything
// (`HealthBackfill.uploadExtras`, `HealthBackfill.uploadMedications`).

extension DependencyValues {
  public var healthCharacteristicsReader: HealthCharacteristicsReader {
    get { self[HealthCharacteristicsReader.self] }
    set { self[HealthCharacteristicsReader.self] = newValue }
  }

  public var healthVisionPrescriptionsReader: HealthVisionPrescriptionsReader {
    get { self[HealthVisionPrescriptionsReader.self] }
    set { self[HealthVisionPrescriptionsReader.self] = newValue }
  }

  public var healthDocumentsReader: HealthDocumentsReader {
    get { self[HealthDocumentsReader.self] }
    set { self[HealthDocumentsReader.self] = newValue }
  }

  public var healthMedicationsReader: HealthMedicationsReader {
    get { self[HealthMedicationsReader.self] }
    set { self[HealthMedicationsReader.self] = newValue }
  }

  public var healthActivitySummaryReader: HealthActivitySummaryReader {
    get { self[HealthActivitySummaryReader.self] }
    set { self[HealthActivitySummaryReader.self] = newValue }
  }
}

/// Reads the characteristics Health lets this app read: date of birth, sex, blood type, skin
/// type, wheelchair use and Activity move mode.
public struct HealthCharacteristicsReader: Sendable {
  public var read: @Sendable () async throws -> [HealthMutation]

  public init(read: @escaping @Sendable () async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthCharacteristicsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self {
      // Each read throws when the app may not read that characteristic; those are left out. A
      // locked device stops the read instead, so they don't look removed.
      func read<T>(_ characteristic: () throws -> T) throws -> T? {
        do {
          return try HealthReader.Locked.mapping(characteristic)
        } catch let locked as HealthReader.Locked {
          throw locked
        } catch {
          return nil
        }
      }
      var mutations: [HealthMutation] = []
      if let birth = try read(store.dateOfBirthComponents) {
        mutations.append(
          HealthEncoder.characteristic(.dateOfBirth, value: HealthEncoder.dateOfBirth(birth)))
      }
      if let sex = try read(store.biologicalSex) {
        mutations.append(
          HealthEncoder.characteristic(
            .biologicalSex, value: HealthEncoder.biologicalSex(sex.biologicalSex)))
      }
      if let blood = try read(store.bloodType) {
        mutations.append(
          HealthEncoder.characteristic(
            .bloodType, value: HealthEncoder.bloodType(blood.bloodType)))
      }
      if let skin = try read(store.fitzpatrickSkinType) {
        mutations.append(
          HealthEncoder.characteristic(
            .fitzpatrickSkinType, value: HealthEncoder.skinType(skin.skinType)))
      }
      if let wheelchair = try read(store.wheelchairUse) {
        mutations.append(
          HealthEncoder.characteristic(
            .wheelchairUse, value: HealthEncoder.wheelchairUse(wheelchair.wheelchairUse)))
      }
      if let move = try read(store.activityMoveMode) {
        mutations.append(
          HealthEncoder.characteristic(
            .activityMoveMode, value: HealthEncoder.activityMoveMode(move.activityMoveMode)))
      }
      return mutations
    }
  }

  public static var testValue: Self {
    Self {
      reportIssue("Unimplemented: @Dependency(\\.healthCharacteristicsReader).read")
      return []
    }
  }
}

/// Reads every vision prescription Health shares with the app (851-2572). Health shares them one
/// by one, and may share one recorded long ago at any time or stop sharing one, which anchored
/// queries don't see, so they're all read every run, as characteristics are. There are a few.
public struct HealthVisionPrescriptionsReader: Sendable {
  public var read: @Sendable () async throws -> [HealthMutation]

  public init(read: @escaping @Sendable () async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthVisionPrescriptionsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self {
      let prescriptions: [HKVisionPrescription]
      do {
        prescriptions = try await HKSampleQueryDescriptor(
          predicates: [.sample(type: HKObjectType.visionPrescriptionType())], sortDescriptors: []
        )
        .result(for: store)
        .compactMap { $0 as? HKVisionPrescription }
      } catch {
        throw HealthReader.Locked.mapped(error)
      }
      return prescriptions.compactMap(HealthEncoder.visionPrescription)
    }
  }

  /// None shared, unless a test says otherwise: most tests aren't about them.
  public static var testValue: Self { Self { [] } }
}

/// Reads the Health Documents (CDA) Health shares with the app (851-2836). HealthKit asks the
/// person about each document new since the app's last document query, when it runs one, and
/// may stop sharing one at any time, which an anchored query doesn't see (its samples never
/// have the XML either). So, like vision prescriptions, which ones are shared is read every run
/// (`shared`), and only those not uploaded yet are read with their XML (`read`), which can be
/// large. Documents are samples, so they never change.
public struct HealthDocumentsReader: Sendable {
  /// The IDs (lowercase UUIDs) of every document Health shares with the app.
  public var shared: @Sendable () async throws -> Set<String>
  /// Those of `ids` still shared, with their XML.
  public var read: @Sendable (_ ids: [String]) async throws -> [DocumentRecord]

  public init(
    shared: @escaping @Sendable () async throws -> Set<String>,
    read: @escaping @Sendable (_ ids: [String]) async throws -> [DocumentRecord]
  ) {
    self.shared = shared
    self.read = read
  }

  /// A document HealthKit gave without its XML, though it was asked for.
  struct MissingXML: Error, Equatable {
    let id: String
  }

  /// Runs an `HKDocumentQuery` for CDA documents to the end. It has no async form, and calls
  /// back on HealthKit's queue, a batch at a time. Cancelling stops it.
  static func documents(
    matching predicate: NSPredicate?, includeXML: Bool, in store: HKHealthStore
  ) async throws -> [HKCDADocumentSample] {
    guard let type = HKObjectType.documentType(forIdentifier: .CDA) else { return [] }
    let found = LockIsolated<[HKCDADocumentSample]>([])
    let waiting = LockIsolated<CheckedContinuation<[HKCDADocumentSample], any Error>?>(nil)
    /// Resumes the caller once, whichever comes first: the end, a failure or cancellation.
    let finish = { @Sendable (result: Result<[HKCDADocumentSample], any Error>) in
      waiting.withValue { continuation in
        continuation?.resume(with: result)
        continuation = nil
      }
    }
    let query = HKDocumentQuery(
      documentType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
      sortDescriptors: nil, includeDocumentData: includeXML
    ) { _, results, done, error in
      guard let results else {
        finish(.failure(HealthReader.Locked.mapped(error ?? CancellationError())))
        return
      }
      found.withValue { $0 += results.compactMap { $0 as? HKCDADocumentSample } }
      if done { finish(.success(found.value)) }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting.setValue(continuation)
        if Task.isCancelled {
          finish(.failure(CancellationError()))
        } else {
          store.execute(query)
        }
      }
    } onCancel: {
      store.stop(query)
      finish(.failure(CancellationError()))
    }
  }
}

extension HealthDocumentsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self(
      shared: {
        let documents = try await documents(matching: nil, includeXML: false, in: store)
        return Set(documents.map { HealthEncoder.id($0.uuid) })
      },
      read: { ids in
        let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !uuids.isEmpty else { return [] }
        let documents = try await documents(
          matching: HKQuery.predicateForObjects(with: uuids), includeXML: true, in: store)
        return documents.compactMap { sample in
          guard let record = DocumentRecord(sample) else {
            reportIssue(MissingXML(id: HealthEncoder.id(sample.uuid)))
            return nil
          }
          return record
        }
      }
    )
  }

  /// None shared, unless a test says otherwise: most tests aren't about them.
  public static var testValue: Self { Self(shared: { [] }, read: { _ in [] }) }
}

/// Reads every medication Health shares with the app (851-2571), current and archived. Health
/// shares them one by one, like vision prescriptions, and they aren't samples, so there's no
/// anchor: they're all read every run of everything (`HealthBackfill.uploadMedications`). Their
/// dose events are samples, read with anchors.
public struct HealthMedicationsReader: Sendable {
  public var read: @Sendable () async throws -> [HealthMutation]

  public init(read: @escaping @Sendable () async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthMedicationsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self {
      let medications: [HKUserAnnotatedMedication]
      do {
        medications = try await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)
      } catch {
        throw HealthReader.Locked.mapped(error)
      }
      return HealthEncoder.medications(medications.map(MedicationRecord.init))
    }
  }

  /// None shared, unless a test says otherwise: most tests aren't about them.
  public static var testValue: Self { Self { [] } }
}

/// Reads Activity summaries, one per day.
public struct HealthActivitySummaryReader: Sendable {
  /// The summaries for the days from `from`'s day through today, or all of them if it's `nil`.
  public var read: @Sendable (_ from: Date?) async throws -> [HealthMutation]

  public init(read: @escaping @Sendable (_ from: Date?) async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthActivitySummaryReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self { from in
      // Activity summaries are days in the user's calendar, as the Fitness app shows them.
      let calendar = Calendar.current
      let predicate = from.map { from in
        let units: Set<Calendar.Component> = [.era, .year, .month, .day]
        var start = calendar.dateComponents(units, from: from)
        var end = calendar.dateComponents(units, from: Date())
        start.calendar = calendar
        end.calendar = calendar
        return HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
      }
      let summaries: [HKActivitySummary]
      do {
        summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(
          for: store)
      } catch {
        throw HealthReader.Locked.mapped(error)
      }
      return summaries.compactMap { summary in
        HealthEncoder.activitySummary(
          summary, day: summary.dateComponents(for: calendar), calendar: calendar)
      }
    }
  }

  public static var testValue: Self {
    Self { _ in
      reportIssue("Unimplemented: @Dependency(\\.healthActivitySummaryReader).read")
      return []
    }
  }
}
