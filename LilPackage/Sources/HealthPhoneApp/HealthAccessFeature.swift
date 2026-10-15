public import ComposableArchitecture
import Foundation
public import HealthKitAccess

/// Onboarding for Health access: what lil health reads and why, then the system sheet, then the
/// separate sheets for medications and vision prescriptions.
@Reducer
public struct HealthAccessFeature {
  @ObservableState
  public struct State: Equatable {
    public var step: Step
    /// Why the last request failed, if it did.
    public var failure: String?

    public enum Step: Equatable {
      /// Explains what's read, before the system sheet.
      case explain
      case requesting
      /// Medications and vision prescriptions, which Health asks about one by one.
      case perObject
    }

    public init(step: Step = .explain, failure: String? = nil) {
      self.step = step
      self.failure = failure
    }
  }

  public enum Action {
    case continueButtonTapped
    case readRequestFinished
    case perObjectButtonTapped(PerObjectHealthType)
    /// A request failed, with why.
    case requestFailed(String)
    case doneButtonTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case finished
    }
  }

  @Dependency(\.healthAuthorization) var healthAuthorization

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .continueButtonTapped:
        state.step = .requesting
        state.failure = nil
        return .run { [healthAuthorization] send in
          do {
            try await healthAuthorization.requestRead()
            await send(.readRequestFinished)
          } catch {
            await send(.requestFailed(error.localizedDescription))
          }
        }

      case .readRequestFinished:
        // HealthKit doesn't say what was granted, so whatever the choices, carry on.
        state.step = .perObject
        return .none

      case .perObjectButtonTapped(let type):
        state.failure = nil
        return .run { [healthAuthorization] send in
          do {
            try await healthAuthorization.requestPerObject(type)
          } catch {
            await send(.requestFailed(error.localizedDescription))
          }
        }

      case .requestFailed(let failure):
        if state.step == .requesting { state.step = .explain }
        state.failure = failure
        return .none

      case .doneButtonTapped:
        return .send(.delegate(.finished))

      case .delegate:
        return .none
      }
    }
  }
}
