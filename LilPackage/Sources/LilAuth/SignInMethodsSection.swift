import AuthenticationServices
public import ComposableArchitecture
public import SwiftUI

/// Account settings' sign-in methods, for a `Form` or `List`: each linked account with an Unlink
/// button (unless it's the last), and a button to link each provider not linked yet.
public struct SignInMethodsSection: View {
  @Bindable var store: StoreOf<SignInMethodsFeature>

  public init(store: StoreOf<SignInMethodsFeature>) {
    self.store = store
  }

  public var body: some View {
    Section {
      switch store.methods {
      case .loading:
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
      case .failed(let message):
        HStack {
          Text(message)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Try Again") { store.send(.retryButtonTapped) }
        }
      case .loaded(let methods):
        ForEach(methods) { method in
          SignInMethodRow(
            method: method, canUnlink: store.canUnlink && !store.isBusy,
            isUnlinking: store.unlinking == method.id
          ) {
            store.send(.unlinkButtonTapped(method))
          }
        }
        ForEach(store.linkableProviders, id: \.self) { provider in
          linkButton(provider)
        }
      }
    } header: {
      // On the header, which is one view: a `Section`'s modifiers go to each of its rows.
      Text("Sign-In Methods")
        .task { await store.send(.task).finish() }
        .alert($store.scope(\.alert, action: \.alert))
    } footer: {
      if let failure = store.failure {
        Text(failure)
          .foregroundStyle(.red)
      } else {
        Text(
          "Sign in to this account with any of these. An account that already signs in to another lil account can't be linked."
        )
      }
    }
  }

  @ViewBuilder private func linkButton(_ provider: SignInMethod.Provider) -> some View {
    let isLinking = store.linking == provider
    switch provider {
    case .apple:
      #if os(macOS)
        // Apple's web page, as on the sign-in screen. Not on a preview deployment, which Apple
        // can't return to.
        if store.authorization.appleWebAPI != nil {
          LinkButton(provider: provider, isLinking: isLinking) {
            store.send(.authorization(.appleWebButtonTapped))
          }
          .disabled(store.isBusy)
        }
      #else
        SignInWithAppleButton(.continue) { request in
          store.send(.authorization(.appleButtonTapped))
          request.requestedScopes = [.email]
          request.nonce = store.authorization.nonceHash
        } onCompletion: { result in
          store.send(
            .authorization(.appleAuthorizationFinished(SignInView.credential(from: result))))
        }
        .frame(height: SignInButtonMetrics.height)
        .disabled(store.isBusy)
        .overlay {
          if isLinking { ProgressView() }
        }
      #endif
    case .google:
      LinkButton(provider: provider, isLinking: isLinking) {
        store.send(.authorization(.googleButtonTapped))
      }
      .disabled(store.isBusy)
    }
  }
}

/// A linked account: its provider and email, and Unlink.
private struct SignInMethodRow: View {
  let method: SignInMethod
  let canUnlink: Bool
  let isUnlinking: Bool
  let unlink: () -> Void

  var body: some View {
    HStack {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(method.provider.name)
          if let email = method.email {
            Text(email)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } icon: {
        ProviderIcon(provider: method.provider)
      }
      Spacer()
      if isUnlinking {
        ProgressView()
          .controlSize(.small)
      } else if canUnlink {
        Button("Unlink", role: .destructive, action: unlink)
          .buttonStyle(.borderless)
      }
    }
  }
}

/// "Link Google Account", with the provider's mark.
private struct LinkButton: View {
  let provider: SignInMethod.Provider
  let isLinking: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Label {
          Text("Link \(provider.name) Account…")
        } icon: {
          ProviderIcon(provider: provider)
        }
        if isLinking {
          Spacer()
          ProgressView()
            .controlSize(.small)
        }
      }
    }
  }
}

/// The provider's mark: the Apple logo, or Google's G.
private struct ProviderIcon: View {
  let provider: SignInMethod.Provider

  var body: some View {
    switch provider {
    case .apple:
      // Apple's logo is black, or white in dark mode, never a tint (its guidelines).
      Image(systemName: "apple.logo")
        .foregroundStyle(.primary)
    case .google:
      Image("GoogleG", bundle: .module)
        .resizable()
        .frame(width: 16, height: 16)
    }
  }
}
