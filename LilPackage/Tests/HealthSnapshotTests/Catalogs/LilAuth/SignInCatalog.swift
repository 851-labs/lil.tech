import ComposableArchitecture
import Foundation
import LilAuth
import SwiftUI
import Testing

// The sign-in screen (`SignInView`), which lil health shows on the Mac and the iPhone: signed out,
// pointed at a preview deployment (with the test account's button), signing in, failed, signed in,
// and with Google's or Apple's page open. Both test targets build this file (the iPhone's,
// `HealthPhoneSnapshotTests`, by reference), each rendering it as its app does: the Mac's offscreen
// at the window's size, the iPhone's full screen in the simulator, with Apple's own button. Apple's
// web page is the Mac's only. Every state is light and dark. `EmptyReducer`, so nothing the
// screen sends changes the state shown. Synthetic data only.

#if os(macOS)
  extension MacSnapshotTests {
    @Test(arguments: signInCatalog.selectedStates)
    func signIn(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let signInCatalog = StateCatalog(
    "Sign In (Mac)", width: 384, minHeight: 420,
    states: signInStates + [
      // The Mac signs in with Apple on Apple's web page, in the browser.
      CatalogState("Apple's page open (the Mac)") {
        signIn(privacyPolicy: true) {
          $0.authorization.appleWebRequest = AppleWebAuthorizationRequest(
            redirectURI: URL(string: "https://api.lil.tech/v1/auth/apple/web")!, nonce: "nonce",
            state: "state")
        }
      }
    ])
#else
  extension PhoneSnapshotTests {
    @Test(arguments: signInCatalog.selectedStates)
    func signIn(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let signInCatalog = StateCatalog(phone: "Sign In (iPhone)", states: signInStates)
#endif

private let signInStates = [
  CatalogState("Signed out") {
    signIn(privacyPolicy: true)
  },
  CatalogState("Pointed at a preview deployment") {
    signIn(privacyPolicy: true) {
      $0.isTestAccountAvailable = true
      // Apple can't return to a preview: the Mac has no Apple button there.
      $0.authorization.appleWebAPI = nil
    }
  },
  CatalogState("Signing in") {
    signIn { $0.status = .signingIn }
  },
  CatalogState("Failed") {
    signIn { $0.status = .failed(SignInError.rejected.message) }
  },
  CatalogState("Sign-up unavailable in region") {
    signIn { $0.status = .failed(SignInError.signUpUnavailableInRegion.message) }
  },
  CatalogState("Signed in") {
    signIn { $0.status = .signedIn }
  },
  CatalogState("Google sheet open") {
    signIn {
      $0.authorization.googleRequest = GoogleAuthorizationRequest(
        clientID: "preview.apps.googleusercontent.com", codeVerifier: "verifier", nonce: "nonce",
        state: "state")
    }
  },
]

/// lil health's sign-in screen, signed out, with Google available as in the app (the test
/// dependency has no Google client ID), then `configure`d. Apple's page is staging's on the Mac
/// (`MacSnapshotTests` unsets `LIL_API_URL`).
@MainActor
private func signIn(
  privacyPolicy: Bool = false, _ configure: (inout SignInFeature.State) -> Void = { _ in }
) -> some View {
  var state = SignInFeature.State()
  state.isTestAccountAvailable = false
  state.authorization.isGoogleAvailable = true
  configure(&state)
  return SignInView(
    store: Store(initialState: state) { EmptyReducer() }, appName: "lil health",
    privacyPolicy: privacyPolicy ? URL(string: "https://lil.tech/privacy") : nil)
}
