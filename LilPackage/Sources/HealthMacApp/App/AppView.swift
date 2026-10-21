public import ComposableArchitecture
import HealthCatalog
import HealthPages
import HealthUI
import LilAuth
public import SwiftUI

/// The main window. The app starts the store's `task`, rather than this view, so the session is
/// followed while the window is closed too, for the Settings window.
public struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      switch store.isSignedIn {
      case nil:
        ProgressView()
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
    // Wide enough for a metric's toolbar beside the sidebar: its title, range and periods
    // (851-2821).
    .frame(minWidth: 800, minHeight: 480)
  }
}

/// iPad Health's sidebar: Summary and Health Details, then the Health categories, and a search for
/// data types.
struct SidebarView: View {
  @Bindable var store: StoreOf<AppFeature>
  @FocusState private var isSearchFocused: Bool

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
              type.name, systemImage: type.category?.symbolName ?? "circle",
              color: type.category?.color ?? .secondary
            )
            .tag(SidebarItem.dataType(type.id))
          }
        }
      } else {
        TintedLabel("Summary", systemImage: "heart.text.square.fill", color: .accentColor)
          .tag(SidebarItem.summary)
        TintedLabel(
          "Health Details", systemImage: "person.text.rectangle.fill", color: .accentColor
        )
        .tag(SidebarItem.healthDetails)
        Section("Health Categories") {
          ForEach(HealthCategory.allCases) { category in
            HealthCategoryLabel(category)
              .tag(SidebarItem.category(category))
          }
        }
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
    // So ⌘← and ⌘→ move the search field's cursor rather than a metric's period.
    .searchFocused($isSearchFocused)
    .focusedSceneValue(\.isSearchFocused, isSearchFocused)
    // A bar, not a plain inset, so the rows scrolling under it fade out behind it (the scroll
    // edge effect) rather than showing through its text (851-2867).
    .safeAreaBar(edge: .bottom, spacing: 0) {
      SyncFooterView(status: store.syncStatus, retry: { store.send(.retrySyncButtonTapped) })
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
  }
}

/// What's selected: Summary's pins, Health Details, a category's metrics, or a metric found by
/// search. A metric's card opens its detail, in the store's `metricPath`, so an intent can open
/// one too.
struct DetailView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    switch store.selection {
    case .summary, nil:
      NavigationStack(path: $store.metricPath) {
        SummaryView(store: store.scope(\.summary, action: \.summary))
          .navigationDestination(for: String.self) { MetricDetail(typeID: $0) }
      }
    case .healthDetails:
      NavigationStack {
        HealthDetailsView()
      }
    case .category(let category):
      NavigationStack(path: $store.metricPath) {
        CategoryView(category: category)
          .navigationDestination(for: String.self) { MetricDetail(typeID: $0) }
      }
      // A new stack for each category, so one's pushed metric doesn't show under another.
      .id(category)
    case .dataType(let id):
      NavigationStack {
        MetricDetail(typeID: id)
      }
      .id(id)
    }
  }
}
