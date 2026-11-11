#if DEBUG
  import Dependencies
  import Foundation
  import HealthUpload
  import Observation

  #if os(iOS)
    import UIKit
  #endif

  /// The Diagnostics screen's checks (851-4173, 851-4190), run by a developer on their own iPhone
  /// with its real Health data. Debug builds only. They keep counts and durations alone, in
  /// memory, for as long as the screen is open: nothing is uploaded, logged or saved.
  @MainActor @Observable
  final class DiagnosticsModel {
    enum SeriesPhase: Equatable {
      case notRun
      case counting(done: Int, of: Int)
      case counted([HealthDiagnostics.SeriesCount])
      case failed(String)
    }

    enum LinksPhase: Equatable {
      case notRun
      case checking
      case checked(
        workouts: HealthDiagnostics.LinkOrder, electrocardiograms: HealthDiagnostics.LinkOrder)
      case failed(String)
    }

    enum WatchPhase: Equatable {
      case off
      case starting
      case watching
      case failed(String)
    }

    /// A workout or ECG that arrived while watching, and its links' counts.
    struct Arrival: Equatable, Identifiable {
      /// Its place among those that arrived: 1, 2, …
      var id: Int
      var kind: HealthDiagnostics.Arrival.Kind
      /// Its linked samples when it arrived, once counted.
      var atArrival: Int?
      /// Its linked samples at the last count.
      var latest: Int?
      /// How long after it arrived the last count was.
      var counted: Duration = .zero
      /// The first count at which the links had changed to what they are now, if they ever did.
      var lastChanged: Duration?
      /// Whether every count is done.
      var isDone = false
      /// Whether a count failed, which ends its counts.
      var failed = false
    }

    private(set) var series: SeriesPhase
    private(set) var links: LinksPhase
    private(set) var watch: WatchPhase
    private(set) var arrivals: [Arrival]

    /// How far back the link order is checked.
    static let linkDays = 90
    /// When an arrival's links are counted again, after it arrived.
    static let recounts: [Duration] = [
      .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
    ]

    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored @Dependency(\.date.now) private var now
    @ObservationIgnored private let client: DiagnosticsClient
    @ObservationIgnored private var seriesTask: Task<Void, Never>?
    @ObservationIgnored private var linksTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(
      client: DiagnosticsClient = .live, series: SeriesPhase = .notRun,
      links: LinksPhase = .notRun, watch: WatchPhase = .off, arrivals: [Arrival] = []
    ) {
      self.client = client
      self.series = series
      self.links = links
      self.watch = watch
      self.arrivals = arrivals
    }

    // MARK: Quantity series

    func countSeriesButtonTapped() {
      if case .counting = series { return }
      let total = client.quantityTypeCount()
      series = .counting(done: 0, of: total)
      seriesTask = Task {
        do {
          let counts = try await client.countSeries { done in
            await self.seriesProgress(done, of: total)
          }
          series = .counted(counts)
        } catch is CancellationError {
          series = .notRun
        } catch {
          series = .failed(error.localizedDescription)
        }
      }
    }

    private func seriesProgress(_ done: Int, of total: Int) {
      guard case .counting = series else { return }
      series = .counting(done: done, of: total)
    }

    // MARK: Link order

    func checkLinkOrderButtonTapped() {
      guard links != .checking else { return }
      links = .checking
      let since = now.addingTimeInterval(-Double(Self.linkDays) * 86_400)
      linksTask = Task {
        do {
          let (workouts, electrocardiograms) = try await client.linkOrder(since)
          links = .checked(workouts: workouts, electrocardiograms: electrocardiograms)
        } catch is CancellationError {
          links = .notRun
        } catch {
          links = .failed(error.localizedDescription)
        }
      }
    }

    // MARK: Watching for new workouts and ECGs

    func startWatchingButtonTapped() {
      guard watch != .starting, watch != .watching else { return }
      watch = .starting
      // The screen must stay on: locked, HealthKit can't be read, and the app is suspended.
      setIdleTimerDisabled(true)
      watchTask = Task {
        do {
          try await withThrowingDiscardingTaskGroup { group in
            for try await event in client.arrivals() {
              switch event {
              case .started:
                watch = .watching
              case .arrived(let arrival):
                let id = arrivals.count + 1
                arrivals.append(Arrival(id: id, kind: arrival.kind))
                group.addTask { await self.follow(id, arrival) }
              }
            }
          }
          // The stream ended on its own, not because watching stopped (which may have started
          // again since).
          if !Task.isCancelled { stopWatching() }
        } catch is CancellationError {
        } catch {
          guard !Task.isCancelled else { return }
          watchTask = nil
          setIdleTimerDisabled(false)
          watch = .failed(error.localizedDescription)
        }
      }
    }

    func stopWatchingButtonTapped() {
      stopWatching()
    }

    private func stopWatching() {
      watchTask?.cancel()
      watchTask = nil
      setIdleTimerDisabled(false)
      watch = .off
    }

    /// Counts an arrival's links now, then at each of `recounts`.
    private func follow(_ id: Int, _ arrival: HealthDiagnostics.Arrival) async {
      guard let first = try? await arrival.countLinks() else {
        return update(id) { $0.failed = true }
      }
      update(id) {
        $0.atArrival = first
        $0.latest = first
      }
      var last = first
      var elapsed = Duration.zero
      for recount in Self.recounts {
        do {
          try await clock.sleep(for: recount - elapsed)
        } catch {
          return
        }
        elapsed = recount
        guard let count = try? await arrival.countLinks() else {
          return update(id) { $0.failed = true }
        }
        update(id) {
          $0.latest = count
          $0.counted = recount
          if count != last { $0.lastChanged = recount }
        }
        last = count
      }
      update(id) { $0.isDone = true }
    }

    private func update(_ id: Int, _ change: (inout Arrival) -> Void) {
      guard let index = arrivals.firstIndex(where: { $0.id == id }) else { return }
      change(&arrivals[index])
    }

    // MARK: Leaving

    /// Stops every check: the screen is gone, and so are its numbers.
    func disappeared() {
      seriesTask?.cancel()
      linksTask?.cancel()
      if watchTask != nil { stopWatching() }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
      #if os(iOS)
        @Dependency(\.context) var context
        if context == .live { UIApplication.shared.isIdleTimerDisabled = disabled }
      #endif
    }
  }

  /// What the Diagnostics screen reads: HealthKit, through `HealthDiagnostics`.
  struct DiagnosticsClient: Sendable {
    var quantityTypeCount: @Sendable () -> Int
    var countSeries:
      @Sendable (_ progress: @escaping @Sendable (_ done: Int) async -> Void) async throws ->
        [HealthDiagnostics.SeriesCount]
    var linkOrder:
      @Sendable (_ since: Date) async throws -> (
        workouts: HealthDiagnostics.LinkOrder, electrocardiograms: HealthDiagnostics.LinkOrder
      )
    var arrivals: @Sendable () -> AsyncThrowingStream<HealthDiagnostics.Watched, any Error>

    static let live = DiagnosticsClient(
      quantityTypeCount: { HealthDiagnostics.quantityTypes.count },
      countSeries: { progress in try await HealthDiagnostics.countSeries(progress: progress) },
      linkOrder: { since in try await HealthDiagnostics.linkOrder(since: since) },
      arrivals: { HealthDiagnostics.arrivals() }
    )
  }
#endif
