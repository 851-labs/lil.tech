#if DEBUG
  import Foundation
  import HealthKit
  import HealthUpload
  import Testing

  /// The Debug-only Diagnostics screen's checks (`HealthDiagnostics`), which a developer runs on
  /// their own iPhone's real Health data: series per type (851-4173), and whether a workout's
  /// linked samples can reach the iPhone after the workout does (851-4190). Here with synthetic
  /// samples, including links added after their workout, as a Watch's sync might add them.
  @Suite(.serialized)
  struct HealthKitDiagnosticsTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let bpm = HKUnit.count().unitDivided(by: .minute())

    /// Each type's samples, its series (`count` over 1), their values together and the largest,
    /// read a page at a time.
    @Test
    func seriesAreCountedByType() async throws {
      let health = try await SyntheticHealthKit.empty()
      try await heartRateSeries(health, count: 120, from: start)
      try await heartRateSeries(health, count: 30, from: start.addingTimeInterval(3600))
      try await health.save(
        (0..<3).map { heartRate(70, at: start.addingTimeInterval(Double(7200 + $0 * 60))) }
          + [
            SyntheticHealthKit.sample(
              HKQuantityTypeIdentifier.stepCount.rawValue, 100, at: start, minutes: 10)
          ])

      let types = [
        HKQuantityType(.heartRate), HKQuantityType(.stepCount), HKQuantityType(.bodyMass),
      ]
      let done = Done()
      let counts = try await HealthDiagnostics.countSeries(
        of: types, in: health.store, pageSize: 2, progress: { await done.append($0) })
      #expect(
        counts == [
          .init(
            type: HKQuantityTypeIdentifier.heartRate.rawValue, samples: 5, series: 2, values: 150,
            largest: 120),
          .init(
            type: HKQuantityTypeIdentifier.stepCount.rawValue, samples: 1, series: 0, values: 0,
            largest: 0),
          .init(
            type: HKQuantityTypeIdentifier.bodyMass.rawValue, samples: 0, series: 0, values: 0,
            largest: 0),
        ])
      #expect(await done.values == [1, 2, 3])
    }

    /// A workout's builder saves the samples added to it before the workout: none came after.
    @Test
    func samplesAddedByItsBuilderComeBeforeTheWorkout() async throws {
      let health = try await SyntheticHealthKit.empty()
      _ = try await run(health, adding: 3)
      let order = try await HealthDiagnostics.linkOrder(
        since: start.addingTimeInterval(-60), in: health.store)
      #expect(
        order.workouts == .init(checked: 1, withLinks: 1, withLateLinks: 0, linked: 3, late: 0))
      // Nothing asked about ECGs, which the tests' host can't write: they're skipped.
      #expect(order.electrocardiograms == .init())
    }

    /// Samples linked to a workout after it was saved, as a sync delivering the workout first
    /// would add them, are found by the workout's anchor, of another type's query; a sample
    /// saved later but not linked isn't counted, and nor is a workout that started before
    /// `since`.
    @Test
    func samplesLinkedAfterTheWorkoutAreLate() async throws {
      let health = try await SyntheticHealthKit.empty()
      let workout = try await run(health, adding: 1)
      try await (health.store as any LateLinking).addSamples(
        [
          heartRate(140, at: start.addingTimeInterval(120)),
          heartRate(150, at: start.addingTimeInterval(180)),
        ],
        to: workout)
      try await health.save([heartRate(99, at: start.addingTimeInterval(240))])
      _ = try await run(health, adding: 2, at: start.addingTimeInterval(-86_400))

      let order = try await HealthDiagnostics.linkOrder(
        since: start.addingTimeInterval(-60), in: health.store)
      #expect(
        order.workouts == .init(checked: 1, withLinks: 1, withLateLinks: 1, linked: 3, late: 2))
    }

    /// What the order can't see: a sample saved before its workout, then linked to it after the
    /// workout was saved, keeps its place, so it isn't late, though a read between the two would
    /// have found the workout without it. Watching new workouts (`arrivals`) sees that.
    @Test
    func aSampleSavedBeforeButLinkedAfterIsNotLate() async throws {
      let health = try await SyntheticHealthKit.empty()
      let early = heartRate(140, at: start.addingTimeInterval(120))
      try await health.save([early])
      let workout = try await run(health, adding: 1)
      try await (health.store as any LateLinking).addSamples([early], to: workout)

      let order = try await HealthDiagnostics.linkOrder(
        since: start.addingTimeInterval(-60), in: health.store)
      #expect(
        order.workouts == .init(checked: 1, withLinks: 1, withLateLinks: 0, linked: 2, late: 0))
    }

    /// Watching starts after what's there: a workout saved since arrives, with its links
    /// counted then and again later, when more have been linked to it.
    @Test
    func aWorkoutArrivesWithItsLinksCountedAgain() async throws {
      let health = try await SyntheticHealthKit.empty()
      _ = try await run(health, adding: 1, at: start.addingTimeInterval(-86_400))
      var events = HealthDiagnostics.arrivals(
        in: health.store, now: { [start] in start.addingTimeInterval(3600) }
      ).makeAsyncIterator()
      guard case .started = try await events.next() else {
        Issue.record("Watching didn't start first")
        return
      }
      let workout = try await run(health, adding: 2)
      guard case .arrived(let arrival) = try await events.next() else {
        Issue.record("The workout didn't arrive")
        return
      }
      #expect(arrival.kind == .workout)
      #expect(try await arrival.countLinks() == 2)
      try await (health.store as any LateLinking).addSamples(
        [heartRate(140, at: start.addingTimeInterval(120))], to: workout)
      #expect(try await arrival.countLinks() == 3)
    }

    /// A 10-minute run from `at` (or `start`), with `adding` heart rates added to it by its
    /// builder.
    private func run(_ health: SyntheticHealthKit, adding count: Int, at: Date? = nil)
      async throws -> HKWorkout
    {
      let from = at ?? start
      let configuration = HKWorkoutConfiguration()
      configuration.activityType = .running
      let builder = HKWorkoutBuilder(
        healthStore: health.store, configuration: configuration, device: nil)
      try await builder.beginCollection(at: from)
      try await builder.addSamples(
        (0..<count).map {
          heartRate(120 + Double($0), at: from.addingTimeInterval(Double($0) * 10))
        })
      try await builder.endCollection(at: from.addingTimeInterval(600))
      return try #require(try await builder.finishWorkout())
    }

    private func heartRate(_ value: Double, at date: Date) -> HKQuantitySample {
      SyntheticHealthKit.sample(HKQuantityTypeIdentifier.heartRate.rawValue, value, at: date)
    }

    @discardableResult
    private func heartRateSeries(_ health: SyntheticHealthKit, count: Int, from: Date)
      async throws -> [HKQuantitySample]
    {
      let builder = HKQuantitySeriesSampleBuilder(
        healthStore: health.store, quantityType: HKQuantityType(.heartRate), startDate: from,
        device: nil)
      for index in 0..<count {
        try builder.insert(
          HKQuantity(unit: bpm, doubleValue: Double(60 + index % 100)),
          at: from.addingTimeInterval(Double(index) * 5))
      }
      return try await builder.finishSeries(metadata: nil, endDate: nil)
    }
  }

  private actor Done {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
  }

  /// `HKHealthStore.addSamples(_:to:)`, deprecated since iOS 17 for `HKWorkoutBuilder`, which
  /// can't link a sample to a workout it has saved. It's how a test adds links after their
  /// workout, as a Watch's sync might. Called through this protocol, which doesn't warn.
  private protocol LateLinking {
    func addSamples(_ samples: [HKSample], to workout: HKWorkout) async throws
  }

  extension HKHealthStore: LateLinking {}
#endif
