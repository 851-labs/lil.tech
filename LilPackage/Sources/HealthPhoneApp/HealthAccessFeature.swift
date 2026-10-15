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
    /// A medications or prescriptions sheet is open.
    public var isChoosing = false

    public enum Step: Equatable {
      /// Explains what's read, before the system sheet.
      case explain
      case requesting
      /// Medications and vision prescriptions, which Health asks about one by one.
      case perObject
    }

    public init(step: Step = .explain, failure: String? = nil, isChoosing: Bool = false) {
      self.step = step
      self.failure = failure
      self.isChoosing = isChoosing
    }
  }

  public enum Action {
    case continueButtonTapped
    case readRequestFinished
    case perObjectButtonTapped(PerObjectHealthType)
    case perObjectRequestFinished
    /// A request failed, with why.
    case requestFailed(String)
    case doneButtonTapped
    /// Skips onboarding for now. It's offered again until Health has nothing left to ask.
    case notNowButtonTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Every step was offered.
      case finished
      case skipped
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
        guard !state.isChoosing else { return .none }
        state.failure = nil
        state.isChoosing = true
        return .run { [healthAuthorization] send in
          do {
            try await healthAuthorization.requestPerObject(type)
            await send(.perObjectRequestFinished)
          } catch {
            await send(.requestFailed(error.localizedDescription))
          }
        }

      case .perObjectRequestFinished:
        state.isChoosing = false
        return .none

      case .requestFailed(let failure):
        if state.step == .requesting { state.step = .explain }
        state.isChoosing = false
        state.failure = failure
        return .none

      case .doneButtonTapped:
        return .send(.delegate(.finished))

      case .notNowButtonTapped:
        return .send(.delegate(.skipped))

      case .delegate:
        return .none
      }
    }
  }
}
