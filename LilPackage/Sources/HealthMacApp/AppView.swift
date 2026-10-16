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
          DetailView(selection: store.selection)
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
      if !store.searchText.isEmpty {
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
    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
  }
}

/// What's selected. Summary and Browse get their own views (851-2580, 851-2579); for now a
/// category lists its data types.
struct DetailView: View {
  let selection: SidebarItem?

  var body: some View {
    switch selection {
    case .summary, nil:
      ContentUnavailableView(
        "Summary", systemImage: "heart.text.square.fill",
        description: Text("Your pinned metrics and highlights will appear here."))
    case .category(let category):
      List(HealthCatalog.types(availableOn: .ios(26)).filter { $0.category == category }, id: \.id)
      {
        type in
        Text(type.name)
      }
      .navigationTitle(category.name)
    case .dataType(let id):
      let type = HealthCatalog.type(id: id)
      ContentUnavailableView(
        type?.name ?? "Unknown Data Type",
        systemImage: type?.category?.symbolName ?? "questionmark",
        description: Text(type?.category?.name ?? ""))
    }
  }
}
