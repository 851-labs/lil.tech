public import ComposableArchitecture
import HealthCatalog
import LilAuth
public import SwiftUI

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
    .task { await store.send(.task).finish() }
  }
}

/// iPad Health's sidebar: Summary, then the Health categories, and a search for data types.
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
        Section("Health Categories") {
          ForEach(HealthCategory.allCases) { category in
            Label {
              Text(category.name)
            } icon: {
              Image(systemName: category.symbolName)
                .foregroundStyle(category.color)
            }
            .tag(SidebarItem.category(category))
          }
        }
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        SyncFooterView(
          status: store.syncStatus, retry: { store.send(.retrySyncButtonTapped) },
          signOut: { store.send(.signOutButtonTapped) })
      }
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
  }
}

/// What's selected: Summary's pins, a category's metrics, or a metric found by search. A
/// metric's card opens its detail.
struct DetailView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    switch store.selection {
    case .summary, nil:
      NavigationStack {
        SummaryView(store: store.scope(\.summary, action: \.summary))
          .navigationDestination(for: String.self) { MetricDetail(typeID: $0) }
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
