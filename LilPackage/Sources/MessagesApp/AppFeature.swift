public import ComposableArchitecture

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var greeting = "Hello"

    public init() {}
  }

  public enum Action {
    case onAppear
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .none
      }
    }
  }
}
