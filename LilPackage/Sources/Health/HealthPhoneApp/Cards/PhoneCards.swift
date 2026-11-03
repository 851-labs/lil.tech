public import Dependencies
import Foundation
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

  /// Opens the database in `directory`. One that's damaged, or from a newer release, is only a
  /// copy of the server's cards, so it starts over and syncs again; if even that fails, the cards
  /// are kept in memory until the app quits, so uploading still works.
  static func open(in directory: URL) -> any DatabaseWriter {
    let file = directory.appending(path: "Cards.sqlite")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      do {
        return try HealthCardStore.make(at: file)
      } catch {
        for suffix in ["", "-wal", "-shm"] {
          try? FileManager.default.removeItem(
            at: directory.appending(path: "Cards.sqlite\(suffix)"))
        }
        return try HealthCardStore.make(at: file)
      }
    } catch {
      reportIssue(error)
      // An in-memory database always opens.
      return try! HealthCardStore.make()
    }
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
