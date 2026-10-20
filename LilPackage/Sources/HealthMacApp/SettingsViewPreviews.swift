import ComposableArchitecture
import Foundation
import LilAuth
import SwiftUI

// In their own file: previewing a file instruments it, and with `ForEach` rows that trips an
// assertion in the macOS `List` (AGENTS.md). Synthetic data only. The Account pane, at the
// window's width: the Settings window shows its tabs in the toolbar, which a preview's tab view
// doesn't.

@MainActor
private func settings(
  methods: SignInMethodsFeature.State.Methods = .loaded([
    SignInMethod(id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
  ]),
  export: DataExportFeature.State.Status = .idle,
  isSignedIn: Bool? = true
) -> some View {
  var state = AppFeature.State(isSignedIn: isSignedIn)
  state.account.signInMethods = SignInMethodsFeature.State(methods: methods)
  state.account.signInMethods.authorization.isGoogleAvailable = true
  state.account.signInMethods.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
  state.account.dataExport.status = export
  // `EmptyReducer`, so the sections' tasks don't replace the state shown.
  return AccountSettingsView(store: Store(initialState: state) { EmptyReducer() })
    .previewFrame(width: SettingsView.width, height: SettingsView.height)
}

#Preview("Account") {
  settings()
}

#Preview("Loading sign-in methods") {
  settings(methods: .loading)
}

#Preview("Sign-in methods failed") {
  settings(methods: .failed(SignInMethodError.unavailable.message))
}

#Preview("Preparing an export") {
  settings(export: .preparing)
}

#Preview("Downloading an export") {
  settings(export: .downloading(0.42))
}

#Preview("Saving an export") {
  settings(export: .saving)
}

#Preview("Export saved") {
  settings(export: .saved(URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")))
}

#Preview("Export failed") {
  settings(export: .failed(DataExportError.unavailable.message))
}

#Preview("Signed out") {
  settings(isSignedIn: false)
}

#Preview("Checking the session") {
  settings(isSignedIn: nil)
}
