import Dependencies
public import GRDB
public import SQLiteData
public import SwiftUI

/// `@Fetch`, following sync at most once a second (851-4045). `@Fetch` observes with a
/// `ValueObservation` that GRDB runs again on the writer, inside every commit that touches what it
/// read, before the next write can start: a page open during a first sync or backfill ran its
/// fetch after every page sync wrote, and held the sync up. This observes the tables health data
/// is in with `throttledObservation` instead: the first value at once, a change after a quiet
/// second at once, and a burst of changes once a second, off the writer.
///
/// As `@Fetch`: give it a request when it's made, or `load(_:)` one, which shows at once (a period
/// changed, a page opened). `isLoading` is only for those: while values refresh as sync writes, it
/// stays `false` and the last value stays, so nothing moves. A failed fetch is `loadError`, with
/// the last value kept, until one succeeds. Fetches run with the dependencies where the request
/// was given. With `fetchesFirstValueAtOnce` (window catalogs), the request it's made with is read
/// at once, on the main thread, one loaded is read in the background, and nothing is observed, as
/// `@Fetch` does with `MainQueueScheduler`.
@MainActor
@propertyWrapper
public struct ThrottledFetch<Value: Sendable>: DynamicProperty {
  @State private var model: ThrottledFetchModel<Value>
  /// The request this was made with, which the model follows when it changes, as `@Fetch` does.
  private let initial: ThrottledFetchModel<Value>.Request?

  public init(wrappedValue: Value) {
    _model = State(initialValue: ThrottledFetchModel(value: wrappedValue, isLoading: false))
    initial = nil
  }

  public init<Request: FetchKeyRequest<Value>>(
    wrappedValue: Value, _ request: Request,
    tables: [any DatabaseRegionConvertible] = HealthDatabase.dataTables
  ) {
    let request = ThrottledFetchModel<Value>.Request(request, tables: tables)
    let model = ThrottledFetchModel(value: wrappedValue, isLoading: true)
    model.readAtOnce(request)
    _model = State(initialValue: model)
    initial = request
  }

  public var wrappedValue: Value { model.value }

  public var projectedValue: Self { self }

  /// Whether a request given is still fetching its first value.
  public var isLoading: Bool { model.isLoading }

  /// Why the last fetch failed, until one succeeds.
  public var loadError: (any Error)? { model.loadError }

  /// Observes `request` instead, and returns once its first value is in.
  public func load<Request: FetchKeyRequest<Value>>(
    _ request: Request, tables: [any DatabaseRegionConvertible] = HealthDatabase.dataTables
  ) async {
    await model.load(ThrottledFetchModel.Request(request, tables: tables))
  }

  public func update() {
    if let initial { model.follow(initial) }
  }
}

extension HealthDatabase {
  /// The tables Health records are in, which sync writes: every table but the cards, pins and
  /// sync's own (`dataTablesAreEveryRecordTable`). A category page reads nearly all of them
  /// (`DataTablesTests` checks what Summary's highlights, Metric Detail, the categories and a
  /// card's page read). A table sync doesn't write can't change while it does.
  public static let dataTables: [any DatabaseRegionConvertible] = [
    HealthSample.tableName, HealthStatistic.tableName, HealthStatisticsDevice.tableName,
    HealthProvenance.tableName, HealthWorkout.tableName, HealthWorkoutRoute.tableName,
    HealthActivitySummary.tableName, HealthAudiogram.tableName, HealthCharacteristic.tableName,
    HealthCorrelation.tableName, HealthDocument.tableName, HealthElectrocardiogram.tableName,
    HealthHeartbeatSeries.tableName, HealthMedication.tableName, HealthMedicationDose.tableName,
    HealthScoredAssessment.tableName, HealthStateOfMind.tableName,
    HealthVisionPrescription.tableName,
  ].map { GRDB.Table<Row>($0) }
}

/// `ThrottledFetch`'s state, kept by SwiftUI as long as the view.
@MainActor
@Observable
final class ThrottledFetchModel<Value: Sendable> {
  /// A request, with what it needs to be fetched where it was given.
  struct Request {
    let id: AnyHashable
    let tables: [any DatabaseRegionConvertible]
    let database: any DatabaseWriter
    let clock: any Clock<Duration>
    /// Given in a window catalog (`fetchesFirstValueAtOnce`), which holds the main queue until
    /// its image is taken: a view's request is read at once, a loaded one in the background, as
    /// `@Fetch` does there, and neither is observed.
    let isCatalog: Bool
    let fetch: @Sendable (Database) throws -> Value

    init<Base: FetchKeyRequest<Value>>(_ request: Base, tables: [any DatabaseRegionConvertible]) {
      @Dependency(\.defaultDatabase) var database
      @Dependency(\.continuousClock) var clock
      @Dependency(\.fetchesFirstValueAtOnce) var fetchesFirstValueAtOnce
      id = AnyHashable(request)
      self.tables = tables
      self.database = database
      self.clock = clock
      isCatalog = fetchesFirstValueAtOnce && Thread.isMainThread
      fetch = withEscapedDependencies { dependencies in
        { db in try dependencies.yield { try request.fetch(db) } }
      }
    }
  }

  private(set) var value: Value
  private(set) var isLoading: Bool
  private(set) var loadError: (any Error)?
  /// The request the view was made with, last time it changed.
  @ObservationIgnored private var followed: AnyHashable?
  /// The request observed, or read.
  @ObservationIgnored private var observed: AnyHashable?
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Callers of `load` waiting for its first value.
  @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

  init(value: Value, isLoading: Bool) {
    self.value = value
    self.isLoading = isLoading
  }

  isolated deinit {
    task?.cancel()
    for continuation in waiting { continuation.resume() }
  }

  /// In a window catalog, reads the view's request now, so its first image has the value.
  func readAtOnce(_ request: Request) {
    guard request.isCatalog else { return }
    followed = request.id
    observed = request.id
    receive(Result { try request.database.read(request.fetch) })
  }

  /// Observes the view's request, if it's new.
  func follow(_ request: Request) {
    guard followed != request.id else { return }
    followed = request.id
    if observed != request.id { start(request) }
  }

  func load(_ request: Request) async {
    guard observed != request.id else {
      if isLoading { await withCheckedContinuation { waiting.append($0) } }
      return
    }
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
      start(request)
    }
  }

  private func start(_ request: Request) {
    observed = request.id
    task?.cancel()
    if !isLoading { isLoading = true }
    // The last request's failure isn't this one's, as `@Fetch`'s new request had none.
    if loadError != nil { loadError = nil }
    guard !request.isCatalog else {
      task = Task { [weak self] in
        let value: Result<Value, any Error>
        do {
          value = .success(try await request.database.read(request.fetch))
        } catch {
          value = .failure(error)
        }
        guard !Task.isCancelled, let self else { return }
        self.receive(value)
      }
      return
    }
    let values = throttledObservation(
      of: request.tables, in: request.database, clock: request.clock, fetch: request.fetch)
    task = Task { [weak self] in
      for await value in values {
        guard !Task.isCancelled, let self else { return }
        self.receive(value)
      }
      // Observing failed to start (its failure was the last value): the next load of this request
      // tries again.
      guard !Task.isCancelled, let self else { return }
      self.observed = nil
      self.stopLoading()
    }
  }

  private func receive(_ value: Result<Value, any Error>) {
    switch value {
    case .success(let value):
      self.value = value
      if loadError != nil { loadError = nil }
    case .failure(let error):
      loadError = error
    }
    stopLoading()
  }

  private func stopLoading() {
    if isLoading { isLoading = false }
    let waiting = waiting
    self.waiting = []
    for continuation in waiting { continuation.resume() }
  }
}
