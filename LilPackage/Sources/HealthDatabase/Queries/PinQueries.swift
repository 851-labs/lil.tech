import GRDB
public import LilSync
import OpenAPIRuntime
public import SQLiteData

extension HealthDatabase {
  /// The pinned data types, in order (851-2641).
  public static func summaryPins(_ db: Database) throws -> [String] {
    try HealthPin.order { ($0.position, $0.id) }.fetchAll(db).map(\.id)
  }

  /// The pins now, then each time they change, e.g. when sync brings another Mac's.
  public static func summaryPinUpdates(
    in database: any DatabaseReader
  ) -> AsyncThrowingStream<[String], any Error> {
    let values = ValueObservation.tracking(summaryPins).values(in: database)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await pins in values { continuation.yield(pins) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The writes that turn the pins `old` into `new`: each pin in `new` at its position, and
  /// deletes for the rest.
  public static func pinMutations(from old: [String], to new: [String]) -> [SyncMutation] {
    let removed = old.filter { !new.contains($0) }.map { SyncMutation.delete("health_pin", id: $0) }
    let pinned = new.enumerated().compactMap { index, id -> SyncMutation? in
      guard let row = try? OpenAPIObjectContainer(unvalidatedValue: ["position": Double(index)])
      else { return nil }
      return .upsert("health_pin", id: id, row: row)
    }
    return removed + pinned
  }
}
