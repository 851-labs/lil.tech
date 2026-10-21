import Dependencies
import SQLiteData

/// The synthetic database (`makePreviewHealthDatabase()`), built once per process.
@MainActor private let previewDatabase = makePreviewHealthDatabase()

/// For previews only: never call it from app code, since it makes the synthetic preview data the
/// app's database. Gives the views a preview builds the preview database, as SQLiteData suggests for previews:
/// every preview whose views read the database calls it first, rather than reading a blank one.
/// A preview context keeps the first preparation in a process, so every preview shares this one
/// database: in Xcode a process per preview, and in Pixelbook one for all (851-2698). Previews only
/// read it.
@MainActor
public func preparePreviewDatabase() {
  prepareDependencies { $0.defaultDatabase = previewDatabase }
}
