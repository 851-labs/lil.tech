public import ComposableArchitecture
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
      case false:
        SignInView(store: store.scope(\.signIn, action: \.signIn), appName: "lil health")
      case true:
        if let healthAccess = store.scope(\.healthAccess, action: \.healthAccess) {
          HealthAccessView(store: healthAccess)
        } else {
          SyncStatusView(store: store.scope(\.syncStatus, action: \.syncStatus))
        }
      }
    }
    .alert($store.scope(\.alert, action: \.alert))
    .task { await store.send(.task).finish() }
  }
}

// `EmptyReducer`: the view's task would replace the state with the real session's.
#Preview("Launching") {
  AppView(store: Store(initialState: AppFeature.State()) { EmptyReducer() })
}

#Preview("Signed out") {
  AppView(store: Store(initialState: AppFeature.State(isSignedIn: false)) { EmptyReducer() })
}

#Preview("Asking for Health access") {
  AppView(
    store: Store(
      initialState: AppFeature.State(isSignedIn: true, healthAccess: HealthAccessFeature.State())
    ) { EmptyReducer() })
}

#Preview("Signed in") {
  AppView(store: Store(initialState: AppFeature.State(isSignedIn: true)) { EmptyReducer() })
}

#Preview("Another iPhone") {
  AppView(
    store: Store(initialState: AppFeature.State(isSignedIn: true, alert: .otherIPhones(1))) {
      EmptyReducer()
    })
}

#Preview("Two other iPhones") {
  AppView(
    store: Store(initialState: AppFeature.State(isSignedIn: true, alert: .otherIPhones(2))) {
      EmptyReducer()
    })
}
