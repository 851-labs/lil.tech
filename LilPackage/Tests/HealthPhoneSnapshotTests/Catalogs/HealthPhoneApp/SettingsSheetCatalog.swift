#if os(iOS)
  import ComposableArchitecture
  import Foundation
  import HealthUpload
  @testable import HealthPhoneApp
  import LilAuth
  import SwiftUI
  import Testing

  // The Settings sheet (`SettingsSheet`), from Sync Status's gear button: signed in with Apple,
  // with and without consent, its sign-in methods loading or failed, and each action's question,
  // progress and failure (withdrawing consent, uploading everything again, choosing medications,
  // deleting the account). Its sections scroll past the screen's height, so the images show the
  // top of the sheet, as the app does. Synthetic data only.

  extension PhoneSnapshotTests {
    @Test(arguments: settingsSheetCatalog.selectedStates)
    func settingsSheet(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let settingsSheetCatalog = StateCatalog(
    phone: "Settings Sheet",
    states: [
      CatalogState("Settings") {
        settings()
      },
      CatalogState("Without consent") {
        settings(consented: false)
      },
      CatalogState("Loading sign-in methods") {
        settings(methods: .loading)
      },
      CatalogState("Sign-in methods failed") {
        settings(methods: .failed(SignInMethodError.unavailable.message))
      },
      CatalogState("Withdraw consent?") {
        settings(SyncStatusFeature.State(alert: .confirmWithdrawal))
      },
      CatalogState("Withdrawing consent") {
        settings(SyncStatusFeature.State(isWithdrawingConsent: true))
      },
      CatalogState("Consent withdrawn") {
        settings(SyncStatusFeature.State(alert: .consentWithdrawn), consented: false)
      },
      CatalogState("Withdrawal failed") {
        settings(
          SyncStatusFeature.State(
            alert: .withdrawalFailed("It isn't possible right now. Please try again later.")))
      },
      CatalogState("Upload everything again?") {
        settings(SyncStatusFeature.State(alert: .confirmUploadEverythingAgain))
      },
      CatalogState("Uploading everything again") {
        settings(SyncStatusFeature.State(isUploadingAgain: true))
      },
      CatalogState("Upload everything again failed") {
        settings(
          SyncStatusFeature.State(
            alert: .uploadAgainFailed("The Internet connection appears to be offline.")))
      },
      CatalogState("Choosing medications") {
        settings(SyncStatusFeature.State(isChoosing: true))
      },
      CatalogState("Choosing failed") {
        settings(
          SyncStatusFeature.State(
            alert: .chooseFailed("Health data is unavailable on this device.")))
      },
      CatalogState("Delete account?") {
        settings(SyncStatusFeature.State(alert: .confirmDeletion))
      },
      CatalogState("Deleting account") {
        settings(SyncStatusFeature.State(isDeletingAccount: true))
      },
      CatalogState("Deleting failed") {
        settings(
          SyncStatusFeature.State(
            alert: .deletionFailed("It isn't possible right now. Please try again later.")))
      },
    ])

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
    // `ifLet`: closing an alert clears it, as the feature does.
    return SettingsSheet(
      store: Store(initialState: state) {
        EmptyReducer<SyncStatusFeature.State, SyncStatusFeature.Action>()
          .ifLet(\.$alert, action: \.alert)
      })
  }
#endif
