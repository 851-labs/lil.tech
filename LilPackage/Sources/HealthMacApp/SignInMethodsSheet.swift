import ComposableArchitecture
import LilAuth
import SwiftUI

/// The account's sign-in methods, in a sheet from the account menu.
struct SignInMethodsSheet: View {
  let store: StoreOf<SignInMethodsFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Form {
        SignInMethodsSection(store: store)
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 440, height: 340)
  }
}
