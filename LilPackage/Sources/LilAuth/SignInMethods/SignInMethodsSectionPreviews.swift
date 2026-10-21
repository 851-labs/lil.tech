import ComposableArchitecture
import SwiftUI

// In their own file: previewing a file instruments it, and with `ForEach` rows that trips an
// assertion in the macOS `List` (AGENTS.md). Synthetic data only.

private let apple = SignInMethod(
  id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
private let google = SignInMethod(id: "idt_google", provider: .google, email: "ada@example.com")

@MainActor
private func section(_ configure: (inout SignInMethodsFeature.State) -> Void) -> some View {
  var state = SignInMethodsFeature.State(methods: .loaded([apple]))
  state.authorization.isGoogleAvailable = true
  state.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
  configure(&state)
  // `EmptyReducer`, so the section's `.task` doesn't replace the state shown.
  return Form {
    SignInMethodsSection(store: Store(initialState: state) { EmptyReducer() })
  }
  .formStyle(.grouped)
  .frame(width: 440, height: 300)
}

#Preview("Apple linked") {
  section { _ in }
}

#Preview("Google linked") {
  // On the Mac, Link Apple Account… shows the Apple logo in a button.
  section { $0.methods = .loaded([google]) }
}

#Preview("Both linked") {
  section { $0.methods = .loaded([apple, google]) }
}

#Preview("Linking Google") {
  section { $0.linking = .google }
}

#Preview("Google in use") {
  section { $0.failure = SignInMethodError.inUse(.google).message }
}

#Preview("Unlinking") {
  section {
    $0.methods = .loaded([apple, google])
    $0.unlinking = google.id
  }
}

#Preview("Loading") {
  section { $0.methods = .loading }
}

#Preview("Couldn't load") {
  section { $0.methods = .failed(SignInMethodError.unavailable.message) }
}
