public import ComposableArchitecture
public import Foundation
import MessagesDatabase

/// Explains why lil messages needs Full Disk Access and re-checks until it's granted.
///
/// Reading `~/Library/Messages/chat.db` is the only thing Full Disk Access unlocks for us, so
/// "granted" means the Messages database can be opened.
@Reducer
public struct FullDiskAccessFeature {
  @ObservableState
  public struct State: Equatable {
    public var isChecking = false

    public init() {}
  }

  public enum Action {
    case appBecameActive
    case checkAgainButtonTapped
    case checkResponse(isGranted: Bool)
    case delegate(Delegate)
    case openSystemSettingsButtonTapped

    @CasePathable
    public enum Delegate {
      case accessGranted
    }
  }

  @Dependency(\.chatDatabase) var chatDatabase
  @Dependency(\.openURL) var openURL

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appBecameActive, .checkAgainButtonTapped:
        state.isChecking = true
        return .run { [chatDatabase] send in
          await send(.checkResponse(isGranted: (try? chatDatabase.reader()) != nil))
        }

      case .checkResponse(isGranted: true):
        state.isChecking = false
        return .send(.delegate(.accessGranted))

      case .checkResponse(isGranted: false):
        state.isChecking = false
        return .none

      case .delegate:
        return .none

      case .openSystemSettingsButtonTapped:
        return .run { [openURL] _ in
          await openURL(.fullDiskAccessSettings)
        }
      }
    }
  }
}

extension URL {
  public static let fullDiskAccessSettings = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  )!
}
