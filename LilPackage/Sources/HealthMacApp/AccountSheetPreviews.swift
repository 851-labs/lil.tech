import ComposableArchitecture
import Foundation
import LilAuth
import SwiftUI

// In their own file: previewing a file instruments it, and with `ForEach` rows that trips an
// assertion in the macOS `List` (AGENTS.md). Synthetic data only.

@MainActor
private func sheet(_ status: DataExportFeature.State.Status) -> some View {
  var state = AccountFeature.State()
  state.signInMethods = SignInMethodsFeature.State(
    methods: .loaded([
      SignInMethod(id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
    ]))
  state.signInMethods.authorization.isGoogleAvailable = true
  state.signInMethods.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
  state.dataExport.status = status
  // `EmptyReducer`, so the sections' tasks don't replace the state shown.
  return AccountSheet(store: Store(initialState: state) { EmptyReducer() })
}

#Preview("Export") {
  sheet(.idle)
}

#Preview("Preparing") {
  sheet(.preparing)
}

#Preview("Downloading") {
  sheet(.downloading(0.42))
}

#Preview("Saving") {
  sheet(.saving)
}

#Preview("Saved") {
  sheet(.saved(URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")))
}

#Preview("Failed") {
  sheet(.failed(DataExportError.unavailable.message))
}
