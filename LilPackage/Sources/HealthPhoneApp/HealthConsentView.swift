public import ComposableArchitecture
public import SwiftUI

public struct HealthConsentView: View {
  let store: StoreOf<HealthConsentFeature>

  public init(store: StoreOf<HealthConsentFeature>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Image(systemName: "hand.raised.square.fill")
          .font(.system(size: 64))
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
        Text("Your Consent")
          .font(.title.bold())
        VStack(alignment: .leading, spacing: 16) {
          Point(
            "heart.text.square", title: "What's uploaded",
            text: """
              The Health data you allow lil health to read, with where each record came from, \
              such as the app or device that recorded it.
              """)
          Point(
            "server.rack", title: "Where",
            text: """
              lil health's servers, run by Cloudflare, possibly outside your country. It's \
              encrypted in transit and at rest, but not end-to-end: the servers can read it to \
              sync it.
              """)
          Point(
            "macbook.and.iphone", title: "Why",
            text: """
              Only to show it on your other devices. It's never sold, used for ads or used to \
              train AI.
              """)
          Point(
            "arrow.uturn.backward", title: "Your choice",
            text: """
              You can withdraw your consent at any time in the app, and delete everything by \
              deleting your account.
              """)
        }
        Link("Read the Privacy Policy", destination: privacyPolicy)
        VStack(spacing: 12) {
          Text(
            """
            By tapping Agree, you explicitly consent to lil health processing your Health data \
            as described above and in the privacy policy.
            """
          )
          .font(.footnote)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          // Above the buttons, so it's in view where Agree was tapped.
          if let failure = store.failure {
            Text(failure)
              .font(.callout)
              .foregroundStyle(.red)
              .multilineTextAlignment(.center)
          }
          Button {
            store.send(.agreeButtonTapped)
          } label: {
            Group {
              if store.isSaving {
                ProgressView()
              } else {
                Text("Agree")
              }
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(store.isSaving)
          Button("Not Now") { store.send(.notNowButtonTapped) }
            .disabled(store.isSaving)
        }
      }
      .padding(32)
    }
  }
}

private struct Point: View {
  let systemImage: String
  let title: String
  let text: String

  init(_ systemImage: String, title: String, text: String) {
    self.systemImage = systemImage
    self.title = title
    self.text = text
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Image(systemName: systemImage)
        .foregroundStyle(.blue)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

#Preview("Asking") {
  HealthConsentView(store: Store(initialState: HealthConsentFeature.State()) { EmptyReducer() })
}

#Preview("Saving") {
  HealthConsentView(
    store: Store(initialState: HealthConsentFeature.State(isSaving: true)) { EmptyReducer() })
}

#Preview("Failed") {
  HealthConsentView(
    store: Store(
      initialState: HealthConsentFeature.State(
        failure: "The privacy policy changed. Update lil health to review it.")
    ) { EmptyReducer() })
}
