public import ComposableArchitecture
import Foundation
public import HealthCatalog
public import LilAuth

/// lil health on the Mac: sign in, then iPad Health's layout, a sidebar of Summary and the
/// Health categories beside what's selected.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the stored session has been checked.
    public var isSignedIn: Bool?
    public var signIn = SignInFeature.State()
    public var selection: SidebarItem? = .summary
    public var searchText = ""

    public init(
      isSignedIn: Bool? = nil, selection: SidebarItem? = .summary, searchText: String = ""
    ) {
      self.isSignedIn = isSignedIn
      self.selection = selection
      self.searchText = searchText
    }

    /// The search, without surrounding spaces.
    public var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// The data types whose names match the search, by category order then name. Every type in
    /// the catalog, whatever iOS version added it: the Mac shows what's synced. Characteristics,
    /// which have no category, aren't data to browse.
    public var searchResults: [HealthDataType] {
      guard !query.isEmpty else { return [] }
      return HealthCategory.allCases.flatMap { category in
        HealthCatalog.all
          .filter { $0.category == category && $0.name.localizedStandardContains(query) }
          .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case task
  }

  @Dependency(\.auth) var auth

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
      .onChange(of: \.query) { _, state in
        // A type found by search goes when the search does: its category takes its place.
        if state.query.isEmpty, case .dataType(let id) = state.selection {
          state.selection =
            HealthCatalog.type(id: id)?.category.map(SidebarItem.category) ?? .summary
        }
        return .none
      }
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .signedInChanged(let isSignedIn):
        state.isSignedIn = isSignedIn
        if !isSignedIn {
          // The next account starts afresh.
          state.signIn = SignInFeature.State()
          state.selection = .summary
          state.searchText = ""
        }
        return .none

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .task:
        return .run { [auth] send in
          for await isSignedIn in await auth.signedInUpdates() {
            await send(.signedInChanged(isSignedIn))
          }
        }
      }
    }
  }
}

/// What the sidebar can select: Summary, a category to browse, or a data type found by search.
public enum SidebarItem: Hashable, Sendable {
  case summary
  case category(HealthCategory)
  case dataType(String)
}
