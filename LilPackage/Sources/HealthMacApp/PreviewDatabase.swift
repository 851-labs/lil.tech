import Dependencies
import HealthDatabase
import SQLiteData

/// Gives the views a preview builds the preview database, as SQLiteData suggests for previews.
/// Every preview whose views read the database calls it first, so none shows whatever an earlier
/// preview prepared: Pixelbook renders them all in one process (851-2698).
@MainActor
func preparePreviewDatabase() {
  prepareDependencies { $0.defaultDatabase = makePreviewHealthDatabase() }
}
