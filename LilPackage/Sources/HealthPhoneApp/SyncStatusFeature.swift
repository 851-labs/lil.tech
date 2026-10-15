public import ComposableArchitecture
public import Foundation
public import HealthCatalog
import HealthKitAccess
public import HealthUpload
import LilAuth

/// The iPhone's main screen: what's uploaded and what isn't.
@Reducer
public struct SyncStatusFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the backfill reports.
    public var progress: HealthBackfill.Progress?
    /// Health still has types to ask about (e.g. the person tapped Not Now).
    public var needsHealthAccess = false

    public init(progress: HealthBackfill.Progress? = nil, needsHealthAccess: Bool = false) {
      self.progress = progress
      self.needsHealthAccess = needsHealthAccess
    }

    public enum Status: Equatable {
      case loading
      case needsHealthAccess
      /// Paused until there's a network connection.
      case offline
      case failed(String)
      case uploading(finishedTypes: Int, totalTypes: Int, records: Int)
      /// Not finished and not running, e.g. iOS paused it or the phone is locked.
      case paused(finishedTypes: Int, totalTypes: Int, records: Int)
      case upToDate(lastUpload: Date?)
    }

    public var status: Status {
      guard let progress else { return .loading }
      if needsHealthAccess { return .needsHealthAccess }
      if let failure = progress.failure, !progress.isRunning {
        return progress.isOffline ? .offline : .failed(failure)
      }
      if !progress.isFinished {
        return progress.isRunning
          ? .uploading(
            finishedTypes: progress.finishedTypes, totalTypes: progress.totalTypes,
            records: progress.uploadedRecords)
          : .paused(
            finishedTypes: progress.finishedTypes, totalTypes: progress.totalTypes,
            records: progress.uploadedRecords)
      }
      return .upToDate(lastUpload: progress.lastUploadAt)
    }

    /// Browse's categories, with how much of each is uploaded.
    public var categories: [CategoryProgress] {
      guard let progress else { return [] }
      let byCategory = Dictionary(grouping: progress.types.values.indices) { index in
        HealthCatalog.type(id: progress.types.keys[index])?.category
      }
      return HealthCategory.allCases.compactMap { category in
        guard let indices = byCategory[category] else { return nil }
        let types = indices.map { progress.types.values[$0] }
        return CategoryProgress(
          category: category,
          finishedTypes: types.filter(\.isDone).count, totalTypes: types.count,
          records: types.map(\.uploadedRecords).reduce(0, +))
      }
    }
  }

  public struct CategoryProgress: Equatable, Identifiable, Sendable {
    public var category: HealthCategory
    public var finishedTypes: Int
    public var totalTypes: Int
    public var records: Int

    public var id: HealthCategory { category }
    public var isDone: Bool { finishedTypes == totalTypes }
  }

  public enum Action {
    case task
    case progressChanged(HealthBackfill.Progress)
    case healthAccessChecked(needsRequest: Bool)
    case retryButtonTapped
    case reviewHealthAccessButtonTapped
    case openSettingsButtonTapped
    case signOutButtonTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Show the Health access onboarding again.
      case reviewHealthAccess
      /// Run the backfill now.
      case retry
    }
  }

  @Dependency(\.auth) var auth
  @Dependency(\.healthAuthorization) var healthAuthorization
  @Dependency(\.healthBackfill) var healthBackfill
  @Dependency(\.openURL) var openURL

  /// The app's page in Settings, where its Health access is.
  static let settingsURL = URL(string: "app-settings:")!

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { [healthBackfill] send in
            for await progress in await healthBackfill.progressUpdates() {
              await send(.progressChanged(progress))
            }
          },
          .run { [healthAuthorization] send in
            let needsRequest = (try? await healthAuthorization.needsRequest()) ?? false
            await send(.healthAccessChecked(needsRequest: needsRequest))
          }
        )

      case .progressChanged(let progress):
        state.progress = progress
        return .none

      case .healthAccessChecked(let needsRequest):
        state.needsHealthAccess = needsRequest
        return .none

      case .retryButtonTapped:
        // Through the app's backfill, so background scheduling and signing out apply.
        return .send(.delegate(.retry))

      case .reviewHealthAccessButtonTapped:
        return .send(.delegate(.reviewHealthAccess))

      case .openSettingsButtonTapped:
        return .run { [openURL] _ in await openURL(Self.settingsURL) }

      case .signOutButtonTapped:
        return .run { [auth] _ in await auth.signOut() }

      case .delegate:
        return .none
      }
    }
  }
}
