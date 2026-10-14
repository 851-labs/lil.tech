public import Dependencies
import Foundation
public import LilAPI

#if os(macOS)
  import SystemConfiguration
#endif

/// What Sign in with Apple hands the app.
public struct AppleCredential: Equatable, Sendable {
  public var identityToken: String
  /// Apple only gives the name on the first sign-in.
  public var givenName: String?
  public var familyName: String?

  public init(identityToken: String, givenName: String? = nil, familyName: String? = nil) {
    self.identityToken = identityToken
    self.givenName = givenName
    self.familyName = familyName
  }
}

/// Why signing in didn't work, worded for the sign-in screen.
public enum SignInError: Error, Equatable, Sendable {
  /// The server didn't accept the provider's token. Signing in again usually works.
  case rejected
  /// Signing in isn't available right now; try again later.
  case unavailable
  case failed(String)

  public var message: String {
    switch self {
    case .rejected: "Signing in didn't work. Please try again."
    case .unavailable: "Signing in isn't available right now. Please try again later."
    case .failed(let reason): "Signing in didn't work: \(reason)"
    }
  }
}

/// The installed app, as the server records it on sign-in.
public struct AuthDevice: Equatable, Sendable {
  public var app: String
  public var platform: Components.Schemas.DeviceInfo.PlatformPayload
  public var name: String?

  public init(app: String, platform: Components.Schemas.DeviceInfo.PlatformPayload, name: String?) {
    self.app = app
    self.platform = platform
    self.name = name
  }

  /// This app on this device, named after its bundle ID unless `app` is given.
  public static func current(app: String? = nil) -> Self {
    #if os(iOS)
      Self(app: app ?? Bundle.main.bundleIdentifier ?? "lil", platform: .ios, name: nil)
    #else
      // The computer's name from System Settings, without `Host`'s slow name lookups.
      Self(
        app: app ?? Bundle.main.bundleIdentifier ?? "lil", platform: .macos,
        name: SCDynamicStoreCopyComputerName(nil, nil) as String?)
    #endif
  }
}

extension DependencyValues {
  /// Signing in and out.
  public var auth: AuthClient {
    get { self[AuthClient.self] }
    set { self[AuthClient.self] = newValue }
  }

  /// The device sign-ins are recorded for. Apps set it at launch, e.g. `.current(app: "health-ios")`.
  public var authDevice: AuthDevice {
    get { self[AuthDeviceKey.self] }
    set { self[AuthDeviceKey.self] = newValue }
  }
}

private enum AuthDeviceKey: DependencyKey {
  static var liveValue: AuthDevice { .current() }
  static var testValue: AuthDevice { AuthDevice(app: "test", platform: .macos, name: nil) }
}

/// Signing in and out, as features use it.
public struct AuthClient: Sendable {
  /// Exchanges Sign in with Apple's token for a session. `nonce` is the raw nonce whose SHA-256
  /// the app gave Apple.
  public var signInWithApple:
    @Sendable (_ credential: AppleCredential, _ nonce: String) async throws(SignInError) -> Void
  public var signOut: @Sendable () async -> Void
  /// Whether the app is signed in, now and after every change.
  public var signedInUpdates: @Sendable () async -> AsyncStream<Bool>

  public init(
    signInWithApple:
      @escaping @Sendable (_ credential: AppleCredential, _ nonce: String) async throws(SignInError)
      -> Void,
    signOut: @escaping @Sendable () async -> Void,
    signedInUpdates: @escaping @Sendable () async -> AsyncStream<Bool>
  ) {
    self.signInWithApple = signInWithApple
    self.signOut = signOut
    self.signedInUpdates = signedInUpdates
  }
}

extension AuthClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    @Dependency(\.authSessions) var sessions
    @Dependency(\.authDevice) var device
    @Dependency(\.date) var date
    return Self(
      signInWithApple: { credential, nonce throws(SignInError) in
        let request = Components.Schemas.AppleSignInRequest(
          identityToken: credential.identityToken,
          nonce: nonce,
          fullName: .init(givenName: credential.givenName, familyName: credential.familyName),
          device: .init(app: device.app, platform: device.platform, name: device.name)
        )
        let output: Operations.AuthApple.Output
        do {
          output = try await api.authApple(body: .json(request))
        } catch {
          throw .failed(error.localizedDescription)
        }
        switch output {
        case .ok(let ok):
          guard let pair = try? ok.body.json else { throw .failed("Unexpected response") }
          await sessions.signedIn(AuthSession(pair, receivedAt: date.now))
        case .unauthorized:
          throw .rejected
        case .serviceUnavailable:
          throw .unavailable
        case .undocumented(let statusCode, _):
          throw .failed("HTTP \(statusCode)")
        }
      },
      signOut: { await sessions.signOut() },
      signedInUpdates: { await sessions.signedInUpdates() }
    )
  }

  public static let previewValue = Self(
    signInWithApple: { _, _ throws(SignInError) in },
    signOut: {},
    signedInUpdates: { AsyncStream { $0.yield(false) } }
  )

  public static var testValue: Self {
    Self(
      signInWithApple: { _, _ throws(SignInError) in
        reportIssue("Unimplemented: @Dependency(\\.auth).signInWithApple")
      },
      signOut: { reportIssue("Unimplemented: @Dependency(\\.auth).signOut") },
      signedInUpdates: {
        reportIssue("Unimplemented: @Dependency(\\.auth).signedInUpdates")
        return AsyncStream { $0.finish() }
      }
    )
  }
}
