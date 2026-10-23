public import ComposableArchitecture
import LilAuth
import LilUI
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
        // Its space, under the spinner `delayedProgress` shows (851-3086).
        Color.clear
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
    .delayedProgress(isLoading: store.isSignedIn == nil)
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
