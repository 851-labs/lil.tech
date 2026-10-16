public import Dependencies
import Foundation
import HealthDatabase
import LilSync
import SQLiteData

extension URL {
  /// The app's own folder in Application Support: the app isn't sandboxed, so the folder is
  /// shared with every app otherwise.
  static var healthAppSupport: URL {
    applicationSupportDirectory.appending(
      path: Bundle.main.bundleIdentifier ?? "tech.lil.health", directoryHint: .isDirectory)
  }
}

extension DependencyValues {
  /// Opens the Mac's local copy of the user's health data and sets up sync into it. Call it from
  /// `prepareDependencies` at launch. The database is in the app's own folder: the app isn't
  /// sandboxed, and SQLiteData's default location is shared by every app.
  public mutating func prepareHealthSync() throws {
    let directory = URL.healthAppSupport
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "Health.sqlite")
    do {
      defaultDatabase = try HealthDatabase.make(at: file)
    } catch {
      // Damaged, or from a newer release: it's only a copy of the server's, so it starts over
      // and syncs again.
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(
          at: directory.appending(path: "Health.sqlite\(suffix)"))
      }
      defaultDatabase = try HealthDatabase.make(at: file)
    }
    sync = .live(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
  }
}
