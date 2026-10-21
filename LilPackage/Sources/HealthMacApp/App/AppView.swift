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
    .frame(minWidth: 720, minHeight: 480)
  }
}

/// iPad Health's sidebar: Summary and Health Details, then the Health categories, and a search for
/// data types.
struct SidebarView: View {
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
            Label {
              Text(type.name)
            } icon: {
              Image(systemName: type.category?.symbolName ?? "circle")
                .foregroundStyle(type.category?.color ?? .secondary)
            }
            .tag(SidebarItem.dataType(type.id))
          }
        }
      } else {
        Label("Summary", systemImage: "heart.text.square.fill")
          .tag(SidebarItem.summary)
        Label("Health Details", systemImage: "person.text.rectangle.fill")
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
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        SyncFooterView(status: store.syncStatus, retry: { store.send(.retrySyncButtonTapped) })
      }
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
  }
}

/// What's selected: Summary's pins, Health Details, a category's metrics, or a metric found by
/// search. A metric's card opens its detail.
struct DetailView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    switch store.selection {
    case .summary, nil:
      NavigationStack {
        SummaryView(store: store.scope(\.summary, action: \.summary))
          .navigationDestination(for: String.self) { MetricDetail(typeID: $0) }
      }
    case .healthDetails:
      NavigationStack {
        HealthDetailsView()
      }
    case .category(let category):
      NavigationStack {
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
