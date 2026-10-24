public import ComposableArchitecture
import HealthCatalog
import HealthUI
import LilAuth
import LilUI
public import SwiftUI

/// The main window. The app starts the store's `task`, rather than this view, so the session is
/// followed while the window is closed too, for the Settings window.
public struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  /// The window's scene ID, which the Settings window opens it by after signing out.
  public static let windowID = "main"

  public var body: some View {
    Group {
      switch store.isSignedIn {
      case nil:
        // Its space, under the spinner `delayedProgress` shows (851-3086).
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case false:
        SignInView(
          store: store.scope(\.signIn, action: \.signIn), appName: "lil health",
          privacyPolicy: privacyPolicy
        )
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case true:
        NavigationSplitView {
          SidebarView(store: store)
        } detail: {
          DetailView(store: store)
        }
      }
    }
    .delayedProgress(isLoading: store.isSignedIn == nil)
    // Wide enough for a metric's toolbar beside the sidebar: its title, range and periods
    // (851-2821).
    .frame(minWidth: 800, minHeight: 480)
  }
}

/// iPad Health's sidebar: Summary, then the Health categories, and a search for data types.
struct SidebarView: View {
  @Bindable var store: StoreOf<AppFeature>
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    SidebarList(store: store)
      .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
      // So ⌘← and ⌘→ move the search field's cursor rather than a metric's period.
      .searchFocused($isSearchFocused)
      .focusedSceneValue(\.isSearchFocused, isSearchFocused)
      // A bar, not a plain inset, so the rows scrolling under it fade out behind it (the scroll
      // edge effect) rather than showing through its text (851-2867). Empty, and no height, while
      // sync is up to date (851-2991). Not animated: it would slide every row with the list's
      // inset, and the footer's delay already keeps it from flickering.
      .safeAreaBar(edge: .bottom, spacing: 0) {
        if store.syncFooter == .shown {
          SyncFooterView(status: store.syncStatus, retry: { store.send(.retrySyncButtonTapped) })
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
  }
}

/// The sidebar's rows: Summary and the Health categories, or what the search found.
struct SidebarList: View {
  @Bindable var store: StoreOf<AppFeature>
  var body: some View {
    List(selection: $store.selection) {
      let results = store.searchResults
      if !store.query.isEmpty {
        Section("Results") {
          if results.isEmpty {
            Text("No Results")
              .foregroundStyle(.secondary)
          }
          ForEach(results, id: \.id) { type in
            TintedLabel(
              type.name, systemImage: type.symbolName,
              color: type.color
            )
            .tag(SidebarItem.dataType(type.id))
          }
        }
      } else {
        TintedLabel("Summary", systemImage: "heart.text.square.fill", color: .accentColor)
          .tag(SidebarItem.summary)
        // Collapses with the chevron its header shows on hover (851-3220).
        Section("Health Categories", isExpanded: Binding(store.$isCategoriesExpanded)) {
          ForEach(HealthCategory.allCases) { category in
            HealthCategoryLabel(category)
              .tag(SidebarItem.category(category))
          }
        }
      }
    }
  }
}

/// What's selected: Summary, a category's metrics, or a metric found by search. Each stack's
/// pushed pages are type IDs in the store's `metricPath` (a metric's row opens its detail), so an
/// intent can open one, and opening a page pops them (851-3030).
struct DetailView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    switch store.selection {
    case .summary, nil:
      stack(for: store.selection) {
        SummaryView(store: store.scope(state: \.cards, action: \.cards))
      }
    case .category(let category):
      stack(for: .category(category)) {
        CategoryView(category: category)
      }
      // A new stack for each category, so one's pushed metric doesn't show under another.
      .id(category)
    case .dataType(let id):
      stack(for: .dataType(id)) {
        MetricDetail(typeID: id)
      }
      .id(id)
    }
  }

  private func stack(
    for selection: SidebarItem?, @ViewBuilder root: () -> some View
  ) -> some View {
    NavigationStack(path: metricPath(for: selection)) {
      root()
        .navigationDestination(for: String.self) { MetricDetail(typeID: $0) }
    }
  }

  /// The metrics a stack shows, for the selection it shows them in: a stack going away as the
  /// selection changes writes its path back, and that mustn't replace what the next one opens.
  private func metricPath(for selection: SidebarItem?) -> Binding<[String]> {
    Binding(
      get: { store.selection == selection ? store.metricPath : [] },
      set: { store.send(.metricPathChanged($0, selection: selection)) }
    )
  }
}
