public import ComposableArchitecture
import Foundation
import HealthUpload

extension SharedKey where Self == AppStorageKey<String?> {
  /// The privacy policy version this iPhone knows consent to processing Health data was given
  /// for, or `nil`. Nothing uploads without it matching `HealthConsentClient.policyVersion`,
  /// including in the background, and the server is asked at each launch.
  public static var healthConsentPolicyVersion: Self {
    appStorage("healthConsentPolicyVersion")
  }
}

/// Explicit consent to processing Health data (GDPR Article 9), asked for after signing in and
/// before Health access: what's uploaded, where and why, and an Agree button.
@Reducer
public struct HealthConsentFeature {
  @ObservableState
  public struct State: Equatable {
    public var isSaving: Bool
    /// Why agreeing failed, if it did.
    public var failure: String?

    public init(isSaving: Bool = false, failure: String? = nil) {
      self.isSaving = isSaving
      self.failure = failure
    }
  }

  public enum Action {
    case agreeButtonTapped
    case agreeFailed(String)
    case agreed
    case notNowButtonTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// The server recorded it.
      case agreed
      /// Nothing uploads until the person agrees from the home screen.
      case notNow
    }
  }

  @Dependency(\.healthConsent) var healthConsent

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .agreeButtonTapped:
        guard !state.isSaving else { return .none }
        state.isSaving = true
        state.failure = nil
        return .run { [healthConsent] send in
          do {
            try await healthConsent.give()
            await send(.agreed)
          } catch {
            await send(.agreeFailed(error.localizedDescription))
          }
        }

      case .agreeFailed(let reason):
        state.isSaving = false
        state.failure = reason
        return .none

      case .agreed:
        state.isSaving = false
        return .send(.delegate(.agreed))

      case .notNowButtonTapped:
        return .send(.delegate(.notNow))

      case .delegate:
        return .none
      }
    }
  }
}
