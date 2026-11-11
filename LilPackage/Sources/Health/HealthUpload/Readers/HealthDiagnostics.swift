#if DEBUG
  public import Foundation
  public import HealthKit

  /// Checks a developer runs on their own iPhone, with its real Health data, from the iPhone's
  /// Debug-only Diagnostics screen (851-4173, 851-4190). Debug builds only: Release builds don't
  /// have it. They read HealthKit and return counts and durations only: no values, dates, names,
  /// sources or IDs, which never leave the functions. Nothing is uploaded, logged or written.
  public enum HealthDiagnostics {}

  // MARK: - Quantity series (851-4173)

  extension HealthDiagnostics {
    /// One quantity type's samples, and those that are series (`count` over 1, 851-4149).
    public struct SeriesCount: Equatable, Sendable, Identifiable {
      /// The HealthKit type's identifier.
      public var type: String
      public var samples: Int
      /// Samples whose `count` is over 1.
      public var series: Int
      /// The values the series hold, together: what the one-time re-read sends.
      public var values: Int
      /// The largest `count`, 0 if there's no series.
      public var largest: Int

      public var id: String { type }

      public init(type: String, samples: Int, series: Int, values: Int, largest: Int) {
        self.type = type
        self.samples = samples
        self.series = series
        self.values = values
        self.largest = largest
      }
    }

    /// Every quantity type the app can read on this iOS, as the backfill reads them.
    public static var quantityTypes: [HKQuantityType] {
      HealthBackfillType.current.filter(\.isQuantity).compactMap {
        $0.sampleType as? HKQuantityType
      }
    }

    /// Counts each type's samples and series, reading every sample a page at a time
    /// (`pageSize`), as the backfill does: HealthKit can't count without reading them. Only the
    /// counts are kept, and each page is let go before the next. `progress` is told how many
    /// types are done.
    public static func countSeries(
      of types: [HKQuantityType] = quantityTypes, in store: HKHealthStore = HKHealthStore(),
      pageSize: Int = 10_000, progress: @Sendable (_ done: Int) async -> Void = { _ in }
    ) async throws -> [SeriesCount] {
      var counts: [SeriesCount] = []
      for (index, type) in types.enumerated() {
        var count = SeriesCount(type: type.identifier, samples: 0, series: 0, values: 0, largest: 0)
        var anchor: HKQueryAnchor?
        while true {
          try Task.checkCancellation()
          let page = try await HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: type)], anchor: anchor, limit: pageSize
          ).result(for: store)
          for sample in page.addedSamples {
            count.samples += 1
            if sample.count > 1 {
              count.series += 1
              count.values += sample.count
              count.largest = max(count.largest, sample.count)
            }
          }
          anchor = page.newAnchor
          if page.addedSamples.count + page.deletedObjects.count < pageSize { break }
        }
        counts.append(count)
        await progress(index + 1)
      }
      return counts
    }
  }

  // MARK: - Link order (851-4190)

  extension HealthDiagnostics {
    /// Whether the samples linked to workouts (or the symptoms to ECGs) reached this iPhone
    /// after their workout or ECG did.
    ///
    /// HealthKit doesn't say when an object was added, but its anchors do say in what order:
    /// an anchored query returns only what was added after its anchor, of any type. A workout's
    /// own anchor (an anchored query for it alone) passed to a query of its linked samples finds
    /// those added after it, and an ECG's its symptoms. Not limited to 1: in the iOS 27.2
    /// simulator, an anchored query of workouts limited to 1 finds none, even without a
    /// predicate, and its anchor comes before every sample.
    ///
    /// It's neither exact way round. A sync that adds a workout and its samples together, in one
    /// transaction, still adds them in some order, and no read could have fallen between them.
    /// And a sample already there when it's linked to a workout saved after it keeps its place,
    /// so it isn't late (`HealthKitDiagnosticsTests`). Whether a read can see a workout without
    /// its links is what ``arrivals(in:)`` watches.
    public struct LinkOrder: Equatable, Sendable {
      /// Workouts, or ECGs with symptoms logged.
      public var checked = 0
      /// Those with any sample (or symptom) linked.
      public var withLinks = 0
      /// Those with a linked sample added after them.
      public var withLateLinks = 0
      /// Linked samples, together.
      public var linked = 0
      /// Linked samples added after their workout or ECG.
      public var late = 0

      public init(
        checked: Int = 0, withLinks: Int = 0, withLateLinks: Int = 0, linked: Int = 0, late: Int = 0
      ) {
        self.checked = checked
        self.withLinks = withLinks
        self.withLateLinks = withLateLinks
        self.linked = linked
        self.late = late
      }

      mutating func add(linked: Int, late: Int) {
        checked += 1
        if linked > 0 { withLinks += 1 }
        if late > 0 { withLateLinks += 1 }
        self.linked += linked
        self.late += late
      }
    }

    /// Workouts that started since `since`, and ECGs with symptoms logged recorded since
    /// `since`, in link order.
    public static func linkOrder(
      since: Date, in store: HKHealthStore = HKHealthStore()
    ) async throws -> (workouts: LinkOrder, electrocardiograms: LinkOrder) {
      let recent = HKQuery.predicateForSamples(withStart: since, end: nil)
      var workouts = LinkOrder()
      var electrocardiograms = LinkOrder()
      for workout in try await HKSampleQueryDescriptor(
        predicates: [.workout(recent)], sortDescriptors: []
      ).result(for: store) {
        try Task.checkCancellation()
        guard let (linked, late) = try await order(of: workout, store) else { continue }
        workouts.add(linked: linked, late: late)
      }
      guard asked(about: .electrocardiogramType(), store) else {
        return (workouts, electrocardiograms)
      }
      for ecg in try await HKSampleQueryDescriptor(
        predicates: [.electrocardiogram(recent)], sortDescriptors: []
      ).result(for: store) where ecg.symptomsStatus == .present {
        try Task.checkCancellation()
        guard let (linked, late) = try await order(of: ecg, store) else { continue }
        electrocardiograms.add(linked: linked, late: late)
      }
      return (workouts, electrocardiograms)
    }

    /// A workout's or ECG's linked samples, and how many of them were added after it; `nil` if
    /// it's gone (deleted since it was found).
    private static func order(of sample: HKSample, _ store: HKHealthStore) async throws
      -> (linked: Int, late: Int)?
    {
      let links = linkPredicates(of: sample)
      let own = try await HKAnchoredObjectQueryDescriptor(
        predicates: [
          .sample(type: sample.sampleType, predicate: HKQuery.predicateForObject(with: sample.uuid))
        ],
        anchor: nil
      ).result(for: store)
      guard !own.addedSamples.isEmpty else { return nil }
      let linked = try await HKSampleQueryDescriptor(predicates: links, sortDescriptors: [])
        .result(for: store).count
      let late = try await HKAnchoredObjectQueryDescriptor(
        predicates: links, anchor: own.newAnchor
      ).result(for: store).addedSamples.count
      return (linked, late)
    }

    /// Whether the app has asked for access to a type, as the app has for every type it reads
    /// (`HealthAuthorization`). A query of one it hasn't fails, as one of the HealthKit tests'
    /// host would of ECGs, which it can't write.
    private static func asked(about type: HKObjectType, _ store: HKHealthStore) -> Bool {
      store.authorizationStatus(for: type) != .notDetermined
    }

    /// The queries of what the upload reads as its links (`HealthReader.links(of:store:)`).
    static func linkPredicates(of sample: HKSample) -> [HKSamplePredicate<HKSample>] {
      switch sample {
      case let workout as HKWorkout:
        let predicate = HKQuery.predicateForObjects(from: workout)
        return HealthReader.linkedTypes(of: workout).map { .sample(type: $0, predicate: predicate) }
      case let ecg as HKElectrocardiogram:
        let predicate = HKQuery.predicateForObjectsAssociated(electrocardiogram: ecg)
        return HealthReader.symptomTypes.map { .sample(type: $0, predicate: predicate) }
      default:
        return []
      }
    }
  }

  // MARK: - Links as they arrive (851-4190)

  extension HealthDiagnostics {
    /// A workout or ECG that arrived while the screen watched, whose links are counted then and
    /// again for a few minutes: what a read of it would have found at each moment.
    public struct Arrival: Sendable {
      public enum Kind: Sendable { case workout, electrocardiogram }
      public var kind: Kind
      /// Its linked samples, now.
      public var countLinks: @Sendable () async throws -> Int

      public init(kind: Kind, countLinks: @escaping @Sendable () async throws -> Int) {
        self.kind = kind
        self.countLinks = countLinks
      }
    }

    /// What watching for workouts and ECGs gives.
    public enum Watched: Sendable {
      /// Watching has started: what arrives from now on is new.
      case started
      case arrived(Arrival)
    }

    /// Workouts and ECGs as HealthKit adds them, once watching has started (`started`): none of
    /// those already there. It ends when the task reading it is cancelled.
    public static func arrivals(in store: HKHealthStore = HKHealthStore())
      -> AsyncThrowingStream<Watched, any Error>
    {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            let types: [HKSampleType] = [.workoutType(), .electrocardiogramType()]
            let descriptor = HKAnchoredObjectQueryDescriptor(
              predicates: types.filter { asked(about: $0, store) }.map { .sample(type: $0) },
              anchor: nil)
            var isFirst = true
            for try await result in descriptor.results(for: store) {
              // The first result is everything already there.
              if isFirst {
                isFirst = false
                continuation.yield(.started)
                continue
              }
              for sample in result.addedSamples {
                let links = linkPredicates(of: sample)
                let arrival = Arrival(kind: sample is HKWorkout ? .workout : .electrocardiogram) {
                  // An ECG without symptoms logged has none to read, as the upload has it.
                  if let ecg = sample as? HKElectrocardiogram, ecg.symptomsStatus != .present {
                    return 0
                  }
                  return try await HKSampleQueryDescriptor(predicates: links, sortDescriptors: [])
                    .result(for: store).count
                }
                continuation.yield(.arrived(arrival))
              }
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
#endif
