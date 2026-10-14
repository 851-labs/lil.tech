public import ComposableArchitecture
import LilAuth
public import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      switch store.isSignedIn {
      case nil:
        ProgressView()
      case false:
        SignInView(store: store.scope(\.signIn, action: \.signIn), appName: "lil health")
      case true:
        HomeView(store: store)
      }
    }
    .task { await store.send(.task).finish() }
  }
}

/// A placeholder until Health access and sync status arrive.
struct HomeView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    NavigationStack {
      ContentUnavailableView(
        "You're signed in",
        systemImage: "heart.text.square",
        description: Text("Syncing your Health data to your Mac is coming soon.")
      )
      .navigationTitle("lil health")
      .toolbar {
        Button("Sign Out") {
          store.send(.signOutButtonTapped)
        }
      }
    }
  }
}

// `EmptyReducer`: the view's task would replace the state with the real session's.
#Preview("Launching") {
  AppView(store: Store(initialState: AppFeature.State()) { EmptyReducer() })
}

#Preview("Signed out") {
  AppView(store: Store(initialState: AppFeature.State(isSignedIn: false)) { EmptyReducer() })
}

#Preview("Signed in") {
  AppView(store: Store(initialState: AppFeature.State(isSignedIn: true)) { EmptyReducer() })
}
