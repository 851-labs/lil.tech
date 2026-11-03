public import Dependencies
import Foundation
import GRDB
import HealthCardStore
import LilAPI
public import LilSync
import SQLiteData

/// The iPhone's copy of the account's cards (851-3205): the one entity it pulls, `health_card`,
/// in a database of its own, `Cards.sqlite`. It never pulls Health data: it uploads that, and
/// computes cards from HealthKit (`docs/decisions/cards.md`). Pulls ask the change feed for
/// cards alone (851-3221), and a bootstrap downloads only their snapshot parts.
public enum PhoneCards {
  /// The iPhone's sync schema number (`docs/sync/protocol.md`): bump it in a release that stores
  /// a new field of `health_card`.
  public static let syncSchema = 1

  /// What the iPhone syncs.
  public static let syncEntities = [HealthCardStore.syncEntity]

  /// The database's folder for `environment` (851-2977): `Cards` in Application Support on a
  /// device, which only uses prod, and a folder per server inside it on a simulator
  /// (`Cards/Servers/api.staging.lil.tech`), as the backfill's state is kept, so signing out of
  /// one server deletes only its cards.
  static func directory(
    for environment: APIEnvironment,
    allowsOverride: Bool = APIEnvironment.allowsOverride,
    applicationSupport: URL = .applicationSupportDirectory
  ) -> URL {
    environment.localDirectory(
      in: applicationSupport.appending(path: "Cards", directoryHint: .isDirectory),
      allowsOverride: allowsOverride)
  }

  /// Opens the database in `directory`. One that's damaged, or from a newer release (after a
  /// downgrade), is only a copy of the server's cards, so it's deleted and synced again. Other
  /// failures (a full disk, say) leave the file, and the writes it may have queued, for the next
  /// launch: the cards are kept in memory until the app quits, so uploading still works.
  static func open(in directory: URL) -> any DatabaseWriter {
    let file = directory.appending(path: "Cards.sqlite")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      do {
        return try openChecked(file)
      } catch let error where startsOver(after: error) {
        for suffix in ["", "-wal", "-shm"] {
          try? FileManager.default.removeItem(
            at: directory.appending(path: "Cards.sqlite\(suffix)"))
        }
        return try openChecked(file)
      }
    } catch {
      reportIssue(error)
      // An in-memory database always opens.
      return try! HealthCardStore.make()
    }
  }

  /// A newer release migrated the database: GRDB leaves migrations it doesn't know alone, which
  /// would leave this release on a schema it doesn't know.
  struct NewerSchema: Error {}

  private static func openChecked(_ file: URL) throws -> any DatabaseWriter {
    let database = try HealthCardStore.make(at: file)
    if try database.read({ try HealthCardStore.migrator.hasBeenSuperseded($0) }) {
      throw NewerSchema()
    }
    return database
  }

  /// Whether the database must start over after `error`: it's not a database, it's damaged, or
  /// it's a newer release's.
  static func startsOver(after error: any Error) -> Bool {
    if error is NewerSchema { return true }
    guard let error = error as? DatabaseError else { return false }
    return [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode)
  }
}

extension DependencyValues {
  /// Sets up syncing the account's cards at launch (851-3205): the iPhone's card database as
  /// `defaultDatabase`, and `sync` for `health_card` alone, its pulls filtered to it.
  public mutating func prepareCardSync() {
    defaultDatabase = PhoneCards.open(in: PhoneCards.directory(for: .current()))
    sync = .live(
      entities: PhoneCards.syncEntities, syncSchema: PhoneCards.syncSchema, filtersChanges: true)
  }
}
