import AppKit
public import ComposableArchitecture
public import Foundation
public import LilAuth

/// Exporting the account's data on the Mac: asks for an export, waits while the server prepares
/// it, downloads the archive with progress, then saves it where the person picks. Or, for an app
/// action (851-2894), into the folder it names, without the panel. One export at a time.
@Reducer
public struct DataExportFeature {
  @ObservableState
  public struct State: Equatable {
    public var status: Status = .idle

    public init(status: Status = .idle) {
      self.status = status
    }

    public enum Status: Equatable {
      case idle
      /// The server is writing a fresh snapshot to export.
      case preparing
      /// The share of the archive downloaded, from 0 to 1.
      case downloading(Double)
      /// Waiting for the person to pick where the archive goes.
      case saving
      case saved(URL)
      case failed(String)
    }

    public var isBusy: Bool {
      switch status {
      case .preparing, .downloading, .saving: true
      case .idle, .saved, .failed: false
      }
    }
  }

  public enum Action {
    case exportButtonTapped
    /// An app action's export into a folder (851-2894): no panel, and the request hears how it
    /// goes and where the archive went. Refused while another export runs.
    case exportToFolderRequested(URL, HealthAppActionRequest)
    case cancelButtonTapped
    case prepared
    case downloadProgressed(Double)
    case downloaded(file: URL, name: String)
    case saved(URL?)
    case failed(String)
    case showInFinderButtonTapped
  }

  enum CancelID { case export }

  /// How often to ask whether a prepared export is ready, and how many times at most: 70 minutes,
  /// past the hour the server may wait out a bulk upload for.
  static let pollInterval: Duration = .seconds(3)
  static let maxPolls = 1_400

  @Dependency(\.continuousClock) var clock
  @Dependency(\.dataExports) var dataExports
  @Dependency(\.archiveSaver) var archiveSaver

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .exportButtonTapped:
        // One export at a time, whichever started it: the button is hidden meanwhile anyway.
        guard !state.isBusy else { return .none }
        state.status = .preparing
        return .run { [clock, dataExports] send in
          let (file, name) = try await Self.download(
            dataExports: dataExports, clock: clock, send: send)
          await send(.downloaded(file: file, name: name))
        } catch: { error, send in
          guard !(error is CancellationError) else { return }
          await send(.failed(Self.failure(error).localizedDescription))
        }
        .cancellable(id: CancelID.export, cancelInFlight: true)

      case .exportToFolderRequested(let folder, let request):
        guard !state.isBusy else {
          return .run { _ in request.finish(.failure(HealthAppActionError.exportRunning)) }
        }
        state.status = .preparing
        return .run { [clock, dataExports, archiveSaver] send in
          // Caught here rather than in `catch:`, which a cancelled effect never reaches: the
          // request is answered however the export ends.
          do {
            // Before waiting on the server: a folder that's missing now won't do in an hour.
            try await archiveSaver.checkFolder(folder)
            request.report(.preparing)
            let (file, name) = try await Self.download(
              dataExports: dataExports, clock: clock, send: send, report: request.report)
            // Cancelled as the download finished: the archive doesn't go into the folder.
            do {
              try Task.checkCancellation()
            } catch {
              try? FileManager.default.removeItem(at: file)
              throw error
            }
            let saved = try await archiveSaver.saveToFolder(file, name, folder)
            await send(.saved(saved))
            request.finish(.success(.exported(saved)))
          } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
              // Cancel in Settings. Signing out fails the request first (`HealthAppActions`).
              request.finish(.failure(HealthAppActionError.exportCancelled))
              return
            }
            let failure = Self.failure(error)
            await send(.failed(failure.localizedDescription))
            request.finish(.failure(failure))
          }
        }
        .cancellable(id: CancelID.export)

      case .cancelButtonTapped:
        state.status = .idle
        return .cancel(id: CancelID.export)

      case .prepared:
        state.status = .downloading(0)
        return .none

      case .downloadProgressed(let share):
        guard case .downloading = state.status else { return .none }
        state.status = .downloading(share)
        return .none

      case .downloaded(let file, let name):
        state.status = .saving
        return .run { [archiveSaver] send in
          await send(.saved(await archiveSaver.save(file, name)))
        }
        .cancellable(id: CancelID.export)

      case .saved(let url):
        state.status = url.map(State.Status.saved) ?? .idle
        return .none

      case .failed(let message):
        state.status = .failed(message)
        return .none

      case .showInFinderButtonTapped:
        guard case .saved(let url) = state.status else { return .none }
        return .run { [archiveSaver] _ in await archiveSaver.reveal(url) }
      }
    }
  }

  /// Asks for an export, waits while the server prepares it, and downloads the archive: its
  /// temporary file and name. Reports progress as actions (`prepared`, `downloadProgressed`),
  /// and to `report`.
  private static func download(
    dataExports: DataExportClient, clock: any Clock<Duration>, send: Send<Action>,
    report: HealthAppActions.Progress = { _ in }
  ) async throws -> (file: URL, name: String) {
    @Sendable func attempt() async throws -> (file: URL, name: String) {
      let url = try await readyURL(dataExports: dataExports, clock: clock)
      await send(.prepared)
      report(.downloading(0))
      for try await event in dataExports.download(url) {
        switch event {
        case .progress(let share):
          await send(.downloadProgressed(share))
          report(.downloading(share))
        case .finished(let file, let name):
          return (file, name)
        }
      }
      throw DataExportError.failed("The download ended early")
    }
    do {
      return try await attempt()
    } catch DataExportError.expired {
      // A link that stopped working is asked for again, once.
      return try await attempt()
    }
  }

  /// Asks for an export, and waits until it's ready: its download URL.
  private static func readyURL(
    dataExports: DataExportClient, clock: any Clock<Duration>
  ) async throws -> URL {
    var export = try await dataExports.request()
    for _ in 0..<maxPolls {
      if let url = export.url { return url }
      try await clock.sleep(for: pollInterval)
      guard let latest = try await dataExports.latest() else {
        throw DataExportError.failed("The export is gone")
      }
      export = latest
    }
    guard let url = export.url else { throw TookTooLong() }
    return url
  }

  /// The server took longer to prepare the export than it ever should (`maxPolls`).
  private struct TookTooLong: Error {}

  /// Why an export failed, as Settings and an app action say it.
  static func failure(_ error: any Error) -> HealthAppActionError {
    switch error {
    case let error as HealthAppActionError: error
    case let error as DataExportError: .exportFailed(error.message)
    case is TookTooLong:
      .exportFailed("Preparing the export is taking longer than usual. Please try again later.")
    default: .exportFailed(DataExportError.failed(error.localizedDescription).message)
    }
  }
}

/// Where a downloaded archive goes: a save panel or a folder, then Finder.
struct ArchiveSaver: Sendable {
  /// Asks where to save `file` (a temporary file), suggesting `name`, and moves it there.
  /// `nil` if the person cancels, and then the file is deleted.
  var save: @Sendable (_ file: URL, _ name: String) async -> URL?
  /// Throws `folderNotFound` or `folderNotWritable` unless `folder` is a folder that can be
  /// written to.
  var checkFolder: @Sendable (_ folder: URL) async throws -> Void
  /// Moves `file` (a temporary file) into `folder` as `name`, or `name 2.tar` and so on if it's
  /// taken. The file is deleted if it can't be moved.
  var saveToFolder: @Sendable (_ file: URL, _ name: String, _ folder: URL) async throws -> URL
  /// Shows the saved archive in Finder.
  var reveal: @Sendable (_ url: URL) async -> Void
}

extension ArchiveSaver: DependencyKey {
  static var liveValue: Self {
    Self(
      save: { file, name in
        let destination = await MainActor.run { () -> URL? in
          let panel = NSSavePanel()
          panel.nameFieldStringValue = name
          panel.directoryURL =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
          return panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination else {
          try? FileManager.default.removeItem(at: file)
          return nil
        }
        do {
          _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
          return destination
        } catch {
          reportIssue(error)
          try? FileManager.default.removeItem(at: file)
          return nil
        }
      },
      checkFolder: { try Self.checkFolder($0) },
      saveToFolder: { try Self.move($0, named: $1, into: $2) },
      reveal: { url in
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    )
  }

  static func checkFolder(_ folder: URL) throws(HealthAppActionError) {
    var isDirectory: ObjCBool = false
    let path = folder.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw .folderNotFound(HealthAppAction.displayPath(folder)) }
    guard FileManager.default.isWritableFile(atPath: path) else {
      throw .folderNotWritable(HealthAppAction.displayPath(folder))
    }
  }

  static func move(_ file: URL, named suggestedName: String, into folder: URL) throws -> URL {
    defer { try? FileManager.default.removeItem(at: file) }
    try checkFolder(folder)
    // Only a name: the server's, but nothing in it may lead out of the folder.
    let lastComponent = (suggestedName as NSString).lastPathComponent
    let name =
      lastComponent.isEmpty || lastComponent.hasPrefix(".") ? "lil-export.tar" : lastComponent
    let base = (name as NSString).deletingPathExtension
    let pathExtension = (name as NSString).pathExtension
    for number in 1...10_000 {
      let candidate =
        number == 1
        ? name : pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
      let destination = folder.appending(path: candidate, directoryHint: .notDirectory)
      do {
        // Fails rather than replacing a file of that name, so a name taken meanwhile isn't lost.
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
      } catch CocoaError.fileWriteFileExists {
        continue
      } catch CocoaError.fileWriteNoPermission {
        throw HealthAppActionError.folderNotWritable(HealthAppAction.displayPath(folder))
      }
    }
    throw HealthAppActionError.exportFailed(
      "Exporting didn't work: \(HealthAppAction.displayPath(folder)) has too many exports.")
  }

  static var testValue: Self {
    Self(
      save: { _, _ in
        reportIssue("Unimplemented: @Dependency(\\.archiveSaver).save")
        return nil
      },
      checkFolder: { _ in reportIssue("Unimplemented: @Dependency(\\.archiveSaver).checkFolder") },
      saveToFolder: { _, _, _ in
        reportIssue("Unimplemented: @Dependency(\\.archiveSaver).saveToFolder")
        throw HealthAppActionError.exportFailed("Unimplemented")
      },
      reveal: { _ in reportIssue("Unimplemented: @Dependency(\\.archiveSaver).reveal") }
    )
  }
}

extension DependencyValues {
  var archiveSaver: ArchiveSaver {
    get { self[ArchiveSaver.self] }
    set { self[ArchiveSaver.self] = newValue }
  }
}

/// Account settings on the Mac: the sign-in methods, and exporting the account's data.
@Reducer
public struct AccountFeature {
  @ObservableState
  public struct State: Equatable {
    public var signInMethods = SignInMethodsFeature.State()
    public var dataExport = DataExportFeature.State()

    public init() {}
  }

  public enum Action {
    case signInMethods(SignInMethodsFeature.Action)
    case dataExport(DataExportFeature.Action)
    case appeared
  }

  public init() {}

  /// Stops what the account's pane started, its sign-in methods' requests and an export: their
  /// answers would be the last account's.
  static func cancel<Action>() -> Effect<Action> {
    .merge(SignInMethodsFeature.cancel(), .cancel(id: DataExportFeature.CancelID.export))
  }

  public var body: some ReducerOf<Self> {
    Scope(\.signInMethods, action: \.signInMethods) {
      SignInMethodsFeature()
    }
    Scope(\.dataExport, action: \.dataExport) {
      DataExportFeature()
    }
    Reduce { state, action in
      switch action {
      case .appeared:
        // The pane's state outlives the window, but a past result (an export saved or failed, a
        // link that failed) isn't news the next time it opens.
        if !state.dataExport.isBusy { state.dataExport.status = .idle }
        state.signInMethods.failure = nil
        return .none
      case .signInMethods, .dataExport:
        return .none
      }
    }
  }
}
