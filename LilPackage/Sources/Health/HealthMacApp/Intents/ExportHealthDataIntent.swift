public import AppIntents
import Dependencies
public import Foundation
import UniformTypeIdentifiers

/// Exports the account's data to a folder from Shortcuts (851-2894): the archive Settings ›
/// Account exports, saved in the folder without asking (Downloads unless it's given one), and
/// returned, so a shortcut can pass it on. Settings shows the export as it goes. Only while
/// access on this Mac is on, like every app action. No Siri phrase: an export is
/// something a shortcut passes on, not something people ask for by voice.
public struct ExportHealthDataIntent: AppIntent, ProgressReportingIntent {
  public static let title: LocalizedStringResource = "Export lil health Data"
  public static let description = IntentDescription(
    "Saves a copy of everything in your lil health account to a folder. Needs Allow access on this Mac, in lil health's Settings › Agents."
  )
  /// Never brings a running app's window forward.
  public static let supportedModes: IntentModes = .background

  @Parameter(
    title: "Folder", description: "Where to save it. Downloads if you don't choose one.",
    supportedContentTypes: [.folder])
  public var folder: IntentFile?

  public init() {}

  public static var parameterSummary: some ParameterSummary {
    Summary("Export lil health data to \(\.$folder)")
  }

  /// The archive, without a dialog: Shortcuts waits for a dialog's Done before it goes on, so
  /// one would stop `shortcuts run` until someone clicks it.
  public func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
    let folder = try Self.folderURL(self.folder)
    // A folder chosen in Shortcuts comes with permission to use it, which macOS checks for
    // protected folders (Desktop, Documents, Downloads) even though the app isn't sandboxed.
    let isAccessing = folder.startAccessingSecurityScopedResource()
    defer { if isAccessing { folder.stopAccessingSecurityScopedResource() } }
    let progress = progress
    progress.totalUnitCount = 100
    let saved = try await Self.export(to: folder) { update in
      switch update {
      case .preparing: progress.completedUnitCount = 0
      case .downloading(let share): progress.completedUnitCount = Int64(share * 100)
      }
    }
    return .result(
      value: IntentFile(
        fileURL: saved, filename: saved.lastPathComponent,
        type: UTType(filenameExtension: saved.pathExtension) ?? .data))
  }

  /// The folder chosen, or Downloads.
  static func folderURL(_ folder: IntentFile?) throws -> URL {
    guard let folder else { return URL.downloadsDirectory }
    guard let url = folder.fileURL else {
      throw HealthAppActionError.folderNotFound(folder.filename)
    }
    return url
  }

  /// Asks the app to export, and waits for the archive. If the system stops waiting first, the
  /// app keeps exporting into the folder, and the error says so.
  static func export(
    to folder: URL, progress: @escaping HealthAppActions.Progress
  ) async throws -> URL {
    let started = LockIsolated(false)
    let result: HealthAppActionResult
    do {
      result = try await HealthAppIntents.perform(
        .export(to: folder),
        progress: { update in
          started.setValue(true)
          progress(update)
        })
    } catch is CancellationError where started.value {
      throw HealthAppActionError.stillExporting(folderName: folder.lastPathComponent)
    }
    guard case .exported(let saved) = result else {
      throw HealthAppActionError.exportFailed("Exporting didn't work.")
    }
    return saved
  }
}
