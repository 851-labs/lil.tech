#if DEBUG
  import Dependencies
  import Foundation
  @testable import HealthPhoneApp
  import HealthUpload
  import LilTestSupport
  import Testing

  /// The Debug-only Diagnostics screen (851-4173, 851-4190): what each check shows as it runs,
  /// and when an arrival's links are counted again. HealthKit's side is `HealthKitDiagnosticsTests`.
  @MainActor
  struct DiagnosticsModelTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func countingSeriesShowsProgressThenTheCounts() async throws {
      let (progressed, finish) = AsyncStream<Void>.makeStream()
      let counts = [
        HealthDiagnostics.SeriesCount(
          type: "HKQuantityTypeIdentifierHeartRate", samples: 10, series: 2, values: 300,
          largest: 200)
      ]
      let model = makeModel(
        DiagnosticsClient(
          quantityTypeCount: { 2 },
          countSeries: { progress in
            await progress(1)
            for await _ in progressed { break }
            await progress(2)
            return counts
          },
          linkOrder: { _ in fatalError() }, arrivals: { fatalError() }))

      model.countSeriesButtonTapped()
      #expect(model.series == .counting(done: 0, of: 2))
      try await eventually { model.series == .counting(done: 1, of: 2) }
      finish.yield()
      try await eventually { model.series == .counted(counts) }
    }

    @Test
    func aFailedCountSaysWhy() async throws {
      let model = makeModel(
        DiagnosticsClient(
          quantityTypeCount: { 2 }, countSeries: { _ in throw Failure() },
          linkOrder: { _ in fatalError() }, arrivals: { fatalError() }))
      model.countSeriesButtonTapped()
      try await eventually { model.series == .failed("Locked") }
    }

    /// The last 90 days' workouts and ECGs.
    @Test
    func linkOrderIsCheckedForTheLast90Days() async throws {
      let since = LockIsolated<Date?>(nil)
      let workouts = HealthDiagnostics.LinkOrder(
        checked: 4, withLinks: 3, withLateLinks: 1, linked: 900, late: 12)
      let model = makeModel(
        DiagnosticsClient(
          quantityTypeCount: { 0 }, countSeries: { _ in [] },
          linkOrder: {
            since.setValue($0)
            return (workouts, .init())
          },
          arrivals: { fatalError() }))
      model.checkLinkOrderButtonTapped()
      #expect(model.links == .checking)
      try await eventually {
        model.links == .checked(workouts: workouts, electrocardiograms: .init())
      }
      #expect(since.value == now.addingTimeInterval(-90 * 86_400))
    }

    /// A workout that arrives has its links counted at once, then at 15 s, 30 s, 1, 2 and 5
    /// minutes, keeping when they last changed.
    @Test
    func anArrivalsLinksAreCountedAgainForFiveMinutes() async throws {
      let clock = ManualClock()
      let (events, arrive) = AsyncThrowingStream<HealthDiagnostics.Watched, any Error>.makeStream()
      let links = LockIsolated(0)
      let model = makeModel(
        DiagnosticsClient(
          quantityTypeCount: { 0 }, countSeries: { _ in [] }, linkOrder: { _ in fatalError() },
          arrivals: { events }),
        clock: clock)

      model.startWatchingButtonTapped()
      #expect(model.watch == .starting)
      arrive.yield(.started)
      try await eventually { model.watch == .watching }
      arrive.yield(.arrived(.init(kind: .workout) { links.value }))
      try await eventually { model.arrivals.first?.atArrival == 0 }

      try await clock.waitUntilAsleep(endingIn: .seconds(15))
      links.setValue(240)
      clock.advance(by: .seconds(15))
      try await clock.waitUntilAsleep(endingIn: .seconds(15))
      #expect(
        model.arrivals == [
          .init(
            id: 1, kind: .workout, atArrival: 0, latest: 240, counted: .seconds(15),
            lastChanged: .seconds(15))
        ])
      links.setValue(250)
      clock.advance(by: .seconds(15))
      for wait in [Duration.seconds(30), .seconds(60), .seconds(180)] {
        try await clock.waitUntilAsleep(endingIn: wait)
        clock.advance(by: wait)
      }
      try await eventually { model.arrivals.first?.isDone == true }
      #expect(
        model.arrivals == [
          .init(
            id: 1, kind: .workout, atArrival: 0, latest: 250, counted: .seconds(300),
            lastChanged: .seconds(30), isDone: true)
        ])
      #expect(model.watch == .watching)

      model.stopWatchingButtonTapped()
      #expect(model.watch == .off)
    }

    /// Leaving the screen stops watching, and the counts that were still going.
    @Test
    func leavingStopsWatching() async throws {
      let clock = ManualClock()
      let (events, arrive) = AsyncThrowingStream<HealthDiagnostics.Watched, any Error>.makeStream()
      let model = makeModel(
        DiagnosticsClient(
          quantityTypeCount: { 0 }, countSeries: { _ in [] }, linkOrder: { _ in fatalError() },
          arrivals: { events }),
        clock: clock)
      model.startWatchingButtonTapped()
      arrive.yield(.started)
      arrive.yield(.arrived(.init(kind: .electrocardiogram) { 1 }))
      try await clock.waitUntilAsleep(endingIn: .seconds(15))
      model.disappeared()
      #expect(model.watch == .off)
      try await eventually { !clock.isAsleep(dueWithin: .seconds(300)) }
      #expect(
        model.arrivals == [.init(id: 1, kind: .electrocardiogram, atArrival: 1, latest: 1)])
    }

    private func makeModel(_ client: DiagnosticsClient, clock: ManualClock = ManualClock())
      -> DiagnosticsModel
    {
      withDependencies {
        $0.continuousClock = clock
        $0.date.now = now
      } operation: {
        DiagnosticsModel(client: client)
      }
    }
  }

  private struct Failure: LocalizedError {
    var errorDescription: String? { "Locked" }
  }
#endif
