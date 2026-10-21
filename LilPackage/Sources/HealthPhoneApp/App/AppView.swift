public import ComposableArchitecture
import LilAuth
public import SwiftUI

public struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase
  /// Whether the app went to the background since it was last in front.
  @State private var wasInBackground = false

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      switch store.isSignedIn {
      case nil:
        ProgressView()
      case false:
        SignInView(
          store: store.scope(\.signIn, action: \.signIn), appName: "lil health",
          privacyPolicy: privacyPolicy)
      case true:
        if let healthConsent = store.scope(\.healthConsent, action: \.healthConsent) {
          HealthConsentView(store: healthConsent)
        } else if let healthAccess = store.scope(\.healthAccess, action: \.healthAccess) {
          HealthAccessView(store: healthAccess)
        } else {
          SyncStatusView(store: store.scope(\.syncStatus, action: \.syncStatus))
        }
      }
    }
    .alert($store.scope(\.alert, action: \.alert))
    .task { await store.send(.task).finish() }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        wasInBackground = true
      case .active where wasInBackground:
        wasInBackground = false
        store.send(.returnedToForeground)
      default:
        break
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

#Preview("Asking for consent") {
  AppView(
    store: Store(
      initialState: AppFeature.State(isSignedIn: true, healthConsent: HealthConsentFeature.State())
    ) { EmptyReducer() })
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

// `ifLet`: closing an alert (e.g. when a snapshot's window goes) clears it, as the feature does.
#Preview("Another iPhone") {
  AppView(
    store: Store(initialState: AppFeature.State(isSignedIn: true, alert: .otherIPhones(1))) {
      EmptyReducer<AppFeature.State, AppFeature.Action>().ifLet(\.$alert, action: \.alert)
    })
}

#Preview("Two other iPhones") {
  AppView(
    store: Store(initialState: AppFeature.State(isSignedIn: true, alert: .otherIPhones(2))) {
      EmptyReducer<AppFeature.State, AppFeature.Action>().ifLet(\.$alert, action: \.alert)
    })
}
