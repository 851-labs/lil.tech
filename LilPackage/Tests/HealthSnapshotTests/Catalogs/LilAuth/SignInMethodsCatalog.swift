import ComposableArchitecture
import Foundation
import LilAuth
import SwiftUI
import Testing

// The account's sign-in methods (`SignInMethodsSection`), which lil health shows in its Settings on
// the Mac and the iPhone: Apple, Google or both linked, linking, a provider already in use,
// unlinking, loading and failed. Both test targets build this file (the iPhone's,
// `HealthPhoneSnapshotTests`, by reference): the Mac's renders the section in a grouped form at
// the Settings window's width, the iPhone's in a form filling the screen. On the Mac, Link Apple
// Account… shows the Apple logo in a button. Every state is light and dark. `EmptyReducer`, so the
// section's task doesn't replace the state shown. Synthetic data only: made-up sign-in methods.

#if os(macOS)
  extension MacSnapshotTests {
    @Test(arguments: signInMethodsCatalog.selectedStates)
    func signInMethods(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let signInMethodsCatalog = StateCatalog(
    "Sign-In Methods (Mac)", width: 440, minHeight: 300, states: signInMethodsStates)
#else
  extension PhoneSnapshotTests {
    @Test(arguments: signInMethodsCatalog.selectedStates)
    func signInMethods(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let signInMethodsCatalog = StateCatalog(
    phone: "Sign-In Methods (iPhone)", states: signInMethodsStates)
#endif

private let signInMethodsStates = [
  CatalogState("Apple linked") {
    section { _ in }
  },
  CatalogState("Google linked") {
    section { $0.methods = .loaded([google]) }
  },
  CatalogState("Both linked") {
    section { $0.methods = .loaded([apple, google]) }
  },
  CatalogState("Linking Google") {
    section { $0.linking = .google }
  },
  CatalogState("Google in use") {
    section { $0.failure = SignInMethodError.inUse(.google).message }
  },
  CatalogState("Unlinking") {
    section {
      $0.methods = .loaded([apple, google])
      $0.unlinking = google.id
    }
  },
  CatalogState("Loading") {
    section { $0.methods = .loading }
  },
  CatalogState("Couldn't load") {
    section { $0.methods = .failed(SignInMethodError.unavailable.message) }
  },
]

private let apple = SignInMethod(
  id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
private let google = SignInMethod(id: "idt_google", provider: .google, email: "ada@example.com")

/// The section in a grouped form, signed in with Apple, with Google and Apple's page available,
/// then `configure`d.
@MainActor
private func section(_ configure: (inout SignInMethodsFeature.State) -> Void) -> some View {
  var state = SignInMethodsFeature.State(methods: .loaded([apple]))
  state.authorization.isGoogleAvailable = true
  state.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
  configure(&state)
  return Form {
    SignInMethodsSection(store: Store(initialState: state) { EmptyReducer() })
  }
  .formStyle(.grouped)
}
