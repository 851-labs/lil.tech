import Foundation
public import GRDB
import Synchronization

/// Values of `fetch`, again whenever a transaction changes `tables`, but at most one fetch per
/// `interval` (851-3237). A first sync or a backfill commits page after page, and observing with
/// `@Fetch` runs its fetch again after each, on the writer, holding the sync up.
///
/// - The first value is fetched at once.
/// - A change after a quiet `interval` is fetched at once too, so a single write shows as soon as
///   it would have.
/// - Changes within `interval` of the last fetch's start are fetched together once it's passed,
///   so the last value is never more than `interval` behind the last write. A fetch that takes
///   longer than a quarter of `interval` spaces the next out to 4 times its length, so fetching
///   takes at most a quarter of a core, however large the data.
///
/// Fetches read from `database` in the background: a pool's readers don't wait for its writer. A
/// fetch that throws is a value too, `.failure`, and observing goes on. Observing stops when the
/// stream's consumer does.
public func throttledObservation<Value: Sendable, C: Clock<Duration>>(
  of tables: [any DatabaseRegionConvertible], in database: any DatabaseWriter,
  interval: Duration = .seconds(1), clock: C,
  fetch: @escaping @Sendable (Database) throws -> Value
) -> AsyncStream<Result<Value, any Error>> {
  AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
    let task = Task {
      // Commits that changed `tables`, counted as they end: a fetch started after one sees it.
      let commits = Mutex(0)
      let (changes, changed) = AsyncStream.makeStream(
        of: Void.self, bufferingPolicy: .bufferingNewest(1))
      defer { changed.finish() }
      // Started on the writer's queue, without blocking a thread while sync writes.
      let observation: AnyDatabaseCancellable
      do {
        observation = try await database.writeWithoutTransaction { _ in
          DatabaseRegionObservation(tracking: tables).start(
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
      } catch {
        continuation.yield(.failure(error))
        continuation.finish()
        return
      }
      defer { observation.cancel() }

      var fetched: Int?
      var nextFetch = clock.now
      var iterator = changes.makeAsyncIterator()
      while !Task.isCancelled {
        if fetched == commits.withLock({ $0 }) {
          // Up to date: wait for the next change. `nil` once cancelled.
          guard await iterator.next() != nil else { return }
          continue
        }
        if clock.now < nextFetch {
          do { try await clock.sleep(until: nextFetch, tolerance: nil) } catch { return }
        }
        let through = commits.withLock { $0 }
        let start = clock.now
        let value: Result<Value, any Error>
        do {
          value = .success(try await database.read(fetch))
        } catch is CancellationError {
          return
        } catch {
          value = .failure(error)
        }
        guard !Task.isCancelled else { return }
        continuation.yield(value)
        fetched = through
        nextFetch = start.advanced(by: max(interval, start.duration(to: clock.now) * 4))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}
