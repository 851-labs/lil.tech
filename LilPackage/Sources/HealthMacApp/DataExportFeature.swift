import AppKit
public import ComposableArchitecture
public import Foundation
public import LilAuth

/// Exporting the account's data on the Mac: asks for an export, waits while the server prepares
/// it, downloads the archive with progress, then saves it where the person picks.
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
        state.status = .preparing
        return .run { [clock, dataExports] send in
          // A link that stopped working (`expired`) is asked for again, once.
          for attempt in 1...2 {
            var export = try await dataExports.request()
            var polls = 0
            while export.url == nil {
              polls += 1
              guard polls <= Self.maxPolls else {
                await send(
                  .failed(
                    "Preparing the export is taking longer than usual. Please try again later."))
                return
              }
              try await clock.sleep(for: Self.pollInterval)
              guard let latest = try await dataExports.latest() else {
                throw DataExportError.failed("The export is gone")
              }
              export = latest
            }
            guard let url = export.url else { return }
            await send(.prepared)
            do {
              for try await event in dataExports.download(url) {
                switch event {
                case .progress(let share): await send(.downloadProgressed(share))
                case .finished(let file, let name):
                  await send(.downloaded(file: file, name: name))
                }
              }
              return
            } catch DataExportError.expired where attempt == 1 {
              continue
            }
          }
        } catch: { error, send in
          guard !(error is CancellationError) else { return }
          let message =
            (error as? DataExportError)?.message
            ?? DataExportError.failed(error.localizedDescription).message
          await send(.failed(message))
        }
        .cancellable(id: CancelID.export, cancelInFlight: true)

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
}

/// Where a downloaded archive goes: a save panel, then Finder.
struct ArchiveSaver: Sendable {
  /// Asks where to save `file` (a temporary file), suggesting `name`, and moves it there.
  /// `nil` if the person cancels, and then the file is deleted.
  var save: @Sendable (_ file: URL, _ name: String) async -> URL?
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
      reveal: { url in
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    )
  }

  static var testValue: Self {
    Self(
      save: { _, _ in
        reportIssue("Unimplemented: @Dependency(\\.archiveSaver).save")
        return nil
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
