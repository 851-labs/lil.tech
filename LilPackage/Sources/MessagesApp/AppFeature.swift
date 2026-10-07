public import ComposableArchitecture
import MessagesDatabase
public import OnboardingFeature

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var fullDiskAccess: FullDiskAccessFeature.State?
    public var hasFullDiskAccess: Bool?

    public init() {}
  }

  public enum Action {
    case accessChecked(isGranted: Bool)
    case fullDiskAccess(FullDiskAccessFeature.Action)
    case task
  }

  @Dependency(\.chatDatabase) var chatDatabase

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .accessChecked(let isGranted):
        state.hasFullDiskAccess = isGranted
        state.fullDiskAccess = isGranted ? nil : FullDiskAccessFeature.State()
        return .none

      case .fullDiskAccess(.delegate(.accessGranted)):
        state.hasFullDiskAccess = true
        state.fullDiskAccess = nil
        return .none

      case .fullDiskAccess:
        return .none

      case .task:
        return .run { [chatDatabase] send in
          await send(.accessChecked(isGranted: (try? chatDatabase.reader()) != nil))
        }
      }
    }
    .ifLet(\.fullDiskAccess, action: \.fullDiskAccess) {
      FullDiskAccessFeature()
    }
  }
}
