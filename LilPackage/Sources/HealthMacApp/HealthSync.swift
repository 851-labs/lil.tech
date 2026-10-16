public import Dependencies
import Foundation
import HealthDatabase
import LilSync
import SQLiteData

extension DependencyValues {
  /// Opens the Mac's local copy of the user's health data and sets up sync into it. Call it from
  /// `prepareDependencies` at launch. The database is in the app's own folder: the app isn't
  /// sandboxed, and SQLiteData's default location is shared by every app.
  public mutating func prepareHealthSync() throws {
    let directory = URL.applicationSupportDirectory.appending(
      path: Bundle.main.bundleIdentifier ?? "tech.lil.health", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaultDatabase = try HealthDatabase.make(at: directory.appending(path: "Health.sqlite"))
    sync = .live(entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema)
  }
}
