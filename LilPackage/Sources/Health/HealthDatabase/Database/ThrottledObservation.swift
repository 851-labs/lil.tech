import Foundation
public import GRDB
import Synchronization

/// Values of `fetch`, again whenever a transaction changes `tables`, but at most one fetch per
/// `interval` (851-3237). A first sync or a backfill commits page after page, and observing with
/// `@Fetch` runs its fetch again after each, on the writer, holding the sync up.
///
/// - The first value is fetched at once, on a reader, even while the writer is busy.
/// - A change after a quiet `interval` is fetched at once too, so a single write shows as soon as
///   it would have.
/// - Changes within `interval` of the last fetch's start are fetched together once it's passed,
///   so the last value is never more than `interval` behind the last write. A fetch that takes
///   longer than a quarter of `interval` spaces the next out to 4 times its length, so fetching
///   takes at most a quarter of a core, however large the data.
///
/// Fetches read from `database` in the background: a pool's readers don't wait for its writer. A
/// fetch that throws is a value too, `.failure`, and observing goes on. Observing tables that
/// can't be observed (one that doesn't exist) is a `.failure` that ends the stream, as a
/// `ValueObservation`'s error ends it. Observing stops when the stream's consumer does.
public func throttledObservation<Value: Sendable, C: Clock<Duration>>(
  of tables: [any DatabaseRegionConvertible], in database: any DatabaseWriter,
  interval: Duration = .seconds(1), clock: C,
  fetch: @escaping @Sendable (Database) throws -> Value
) -> AsyncStream<Result<Value, any Error>> {
  AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
    let task = Task {
      // Commits that changed `tables` since observing started, counted as they end: a fetch
      // started after one sees it.
      let commits = Mutex(0)
      let (changes, changed) = AsyncStream.makeStream(
        of: Void.self, bufferingPolicy: .bufferingNewest(1))
      let observation = Mutex<(stopped: Bool, cancellable: AnyDatabaseCancellable?)>(
        (false, nil))
      defer {
        changed.finish()
        observation.withLock {
          $0.stopped = true
          return $0.cancellable
        }?.cancel()
      }
      // Observing starts on the writer's queue, queued before the first read: at once when the
      // writer's free, else after its write, while the first value is read from a reader.
      let (started, isStarted) = AsyncStream.makeStream(of: Void.self)
      database.asyncWriteWithoutTransaction { _ in
        observation.withLock { state in
          guard !state.stopped else { return }
          state.cancellable = DatabaseRegionObservation(tracking: tables).start(
            in: database,
            onError: { error in
              continuation.yield(.failure(error))
              continuation.finish()
            },
            onChange: { _ in
              commits.withLock { $0 += 1 }
              changed.yield()
            })
        }
        isStarted.finish()
      }

      /// Commits the last value was fetched after, or `nil` to fetch again.
      var fetched: Int?
      var nextFetch = clock.now
      var iterator = changes.makeAsyncIterator()
      while !Task.isCancelled {
        if let fetched, fetched == commits.withLock({ $0 }) {
          // Up to date: wait for the next change. `nil` once cancelled.
          guard await iterator.next() != nil else { return }
          continue
        }
        if clock.now < nextFetch {
          do { try await clock.sleep(until: nextFetch, tolerance: nil) } catch { return }
        }
        let start = clock.now
        let through = commits.withLock { $0 }
        let value: Result<Value, any Error>
        let took: Duration
        let observed: Bool
        do {
          // Timed in the read, so waiting for a reader doesn't count as the fetch's own time.
          (value, took, observed) = try await database.read { db in
            // Before the read's first statement, which starts its snapshot.
            let observed = observation.withLock { $0.cancellable != nil }
            let start = clock.now
            let value = Result { try fetch(db) }
            return (value, start.duration(to: clock.now), observed)
          }
        } catch is CancellationError {
          return
        } catch {
          (value, took) = (.failure(error), .zero)
          observed = observation.withLock { $0.cancellable != nil }
        }
        guard !Task.isCancelled else { return }
        continuation.yield(value)
        nextFetch = start.advanced(by: max(interval, took * 4))
        if observed {
          fetched = through
        } else {
          // Read before observing started, while the writer was busy: a commit in between went
          // unseen, so fetch again once observing has.
          fetched = nil
          for await _ in started {}
        }
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}
