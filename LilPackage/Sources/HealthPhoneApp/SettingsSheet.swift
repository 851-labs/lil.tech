import ComposableArchitecture
import HealthKitAccess
import LilAuth
import SwiftUI

/// The account's settings, in a sheet from the main screen's gear button (851-2758): its
/// sign-in methods, Health access, the privacy policy, consent, signing out and deleting it. It
/// shows the alerts those ask and answer with, and can't be closed while one of them is busy.
struct SettingsSheet: View {
  @Bindable var store: StoreOf<SyncStatusFeature>

  /// Whether this is a preview, which uses preview dependencies (`SWIFT_DEPENDENCIES_CONTEXT`).
  @Dependency(\.context) private var context
  private var isPreview: Bool { context == .preview }
  /// Withdrawing consent or deleting the account: the sheet waits behind a progress overlay.
  private var isBusy: Bool { store.isDeletingAccount || store.isWithdrawingConsent }

  var body: some View {
    NavigationStack {
      List {
        SignInMethodsSection(store: store.scope(\.signInMethods, action: \.signInMethods))
        if store.hasConsent {
          Section {
            Button {
              store.send(.uploadEverythingAgainButtonTapped)
            } label: {
              if store.isUploadingAgain {
                // Catching up first.
                LabeledContent("Checking for Changes…") { ProgressView() }
              } else {
                Text("Upload Everything Again")
              }
            }
            .disabled(store.isUploadingAgain)
          } footer: {
            Text(
              "If you let Health share more of your history, such as All Recorded Data rather than the past 30 days, this uploads the older data too."
            )
          }
        }
        // Health doesn't let apps open its access settings, so the sheet says where they are, and
        // offers its pickers for what's shared one by one (851-2775), once there's consent to
        // upload what they share.
        if store.hasConsent {
          Section {
            ForEach(PerObjectHealthType.allCases, id: \.self) { type in
              Button(type.chooseTitle) { store.send(.chooseButtonTapped(type)) }
            }
            .disabled(store.isChoosing || store.isUploadingAgain)
          } header: {
            Text("Health Access")
          } footer: {
            Text(
              "To change what else lil health can read, go to Settings › Privacy & Security › Health › lil health."
            )
          }
        }
        Section {
          Link("Privacy Policy", destination: privacyPolicy)
          if store.hasConsent {
            Button("Withdraw Consent") { store.send(.withdrawConsentButtonTapped) }
          }
          Button("Sign Out") { store.send(.signOutButtonTapped) }
          Button("Delete Account", role: .destructive) {
            store.send(.deleteAccountButtonTapped)
          }
        }
        #if targetEnvironment(simulator)
          // Not in previews (Xcode's or Pixelbook's), which also run in the simulator.
          if !isPreview {
            SyntheticHealthSection()
          }
        #endif
      }
      .navigationTitle("Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.send(.settingsPresented(false)) }
            .disabled(store.isSettingsBusy)
        }
      }
      .disabled(isBusy)
      .overlay {
        if isBusy {
          ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            ProgressView(
              store.isDeletingAccount ? "Deleting your account…" : "Withdrawing your consent…")
          }
        }
      }
      .alert($store.scope(\.alert, action: \.alert))
    }
    .interactiveDismissDisabled(store.isSettingsBusy)
  }
}

extension PerObjectHealthType {
  /// Its button, here and in the Health access setup.
  var chooseTitle: String {
    switch self {
    case .medications: "Choose Medications…"
    case .visionPrescriptions: "Choose Vision Prescriptions…"
    }
  }
}
