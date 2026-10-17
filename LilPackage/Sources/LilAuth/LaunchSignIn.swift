public import Dependencies
import Foundation

extension DependencyValues {
  /// Whether the app signs in to the test account by itself, for scripted end-to-end runs.
  public var launchSignIn: LaunchSignIn {
    get { self[LaunchSignIn.self] }
    set { self[LaunchSignIn.self] = newValue }
  }
}

/// Signing in to the test account without a tap, for scripted end-to-end runs:
/// `LIL_SIGN_IN_TO_TEST_ACCOUNT=1` in the environment, e.g.
/// `open -n --env LIL_API_URL=… --env LIL_SIGN_IN_TO_TEST_ACCOUNT=1 "lil health.app"`. Only where
/// the test account is offered (`SignInFeature.State.isTestAccountAvailable`).
public struct LaunchSignIn: Sendable {
  /// Whether to sign in now. True at most once per launch, so signing out stays signed out.
  public var claim: @Sendable () -> Bool

  public init(claim: @escaping @Sendable () -> Bool) {
    self.claim = claim
  }
}

extension LaunchSignIn: DependencyKey {
  public static let liveValue = once(
    ProcessInfo.processInfo.environment["LIL_SIGN_IN_TO_TEST_ACCOUNT"] == "1")

  /// Claimed the first time only, if `asked`.
  static func once(_ asked: Bool) -> Self {
    let pending = LockIsolated(asked)
    return Self {
      pending.withValue { pending in
        defer { pending = false }
        return pending
      }
    }
  }

  public static let testValue = Self { false }
  public static let previewValue = Self { false }
}
