import ComposableArchitecture
import Foundation
import HealthUpload
import LilAuth
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only.

@MainActor
private func settings(
  _ state: SyncStatusFeature.State = SyncStatusFeature.State(), consented: Bool = true,
  methods: SignInMethodsFeature.State.Methods = .loaded([
    SignInMethod(id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
  ])
) -> some View {
  var state = state
  state.$consentedPolicyVersion.withLock {
    $0 = consented ? HealthConsentClient.policyVersion : nil
  }
  state.signInMethods = SignInMethodsFeature.State(methods: methods)
  state.signInMethods.authorization.isGoogleAvailable = true
  // `EmptyReducer`: the sections' tasks would replace the state shown.
  // `ifLet`: closing an alert (e.g. when a snapshot's window goes) clears it, as the feature does.
  return SettingsSheet(
    store: Store(initialState: state) {
      EmptyReducer<SyncStatusFeature.State, SyncStatusFeature.Action>()
        .ifLet(\.$alert, action: \.alert)
    })
}

#Preview("Settings") {
  settings()
}

#Preview("Without consent") {
  settings(consented: false)
}

#Preview("Loading sign-in methods") {
  settings(methods: .loading)
}

#Preview("Sign-in methods failed") {
  settings(methods: .failed(SignInMethodError.unavailable.message))
}

#Preview("Withdraw consent?") {
  settings(SyncStatusFeature.State(alert: .confirmWithdrawal))
}

#Preview("Withdrawing consent") {
  settings(SyncStatusFeature.State(isWithdrawingConsent: true))
}

#Preview("Consent withdrawn") {
  settings(SyncStatusFeature.State(alert: .consentWithdrawn), consented: false)
}

#Preview("Withdrawal failed") {
  settings(
    SyncStatusFeature.State(
      alert: .withdrawalFailed("It isn't possible right now. Please try again later.")))
}

#Preview("Delete account?") {
  settings(SyncStatusFeature.State(alert: .confirmDeletion))
}

#Preview("Deleting account") {
  settings(SyncStatusFeature.State(isDeletingAccount: true))
}

#Preview("Deleting failed") {
  settings(
    SyncStatusFeature.State(
      alert: .deletionFailed("It isn't possible right now. Please try again later.")))
}
