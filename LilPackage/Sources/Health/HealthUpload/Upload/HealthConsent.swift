public import Dependencies
public import Foundation
import IssueReporting
import LilAPI

/// Consent to processing Health data (`/v1/me/consents/health`). The server takes uploads only
/// with consent to the current privacy policy version.
public struct HealthConsentClient: Sendable {
  /// Whether consent to `policyVersion` is in force.
  public var isGiven: @Sendable () async throws -> Bool
  /// Consents to `policyVersion`. Throws `Outdated` when the server requires a newer one.
  public var give: @Sendable () async throws -> Void
  /// Withdraws consent: the server takes no more uploads.
  public var withdraw: @Sendable () async throws -> Void

  public init(
    isGiven: @escaping @Sendable () async throws -> Bool,
    give: @escaping @Sendable () async throws -> Void,
    withdraw: @escaping @Sendable () async throws -> Void
  ) {
    self.isGiven = isGiven
    self.give = give
    self.withdraw = withdraw
  }

  /// The privacy policy version (its effective date) the consent screen describes. Bump it with
  /// the screen when the server's goes up.
  public static let policyVersion = "2026-10-15"

  public struct Failed: LocalizedError, Equatable {
    public let statusCode: Int

    public var errorDescription: String? {
      statusCode == 429
        ? "Too many requests. Try again in a minute."
        : "lil health's server couldn't do that right now (HTTP \(statusCode)). Try again later."
    }
  }

  /// The privacy policy changed since this version of the app.
  public struct Outdated: LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? {
      "The privacy policy changed. Update lil health to review it."
    }
  }
}

extension HealthConsentClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    return Self(
      isGiven: {
        switch try await api.healthConsent() {
        case .ok(let ok):
          let consent = try ok.body.json
          return consent.current && consent.given?.policyVersion == policyVersion
        case .unauthorized: throw Failed(statusCode: 401)
        case .tooManyRequests: throw Failed(statusCode: 429)
        case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
        }
      },
      give: {
        switch try await api.giveHealthConsent(body: .json(.init(policyVersion: policyVersion))) {
        case .ok: return
        case .conflict: throw Outdated()
        case .unauthorized: throw Failed(statusCode: 401)
        case .tooManyRequests: throw Failed(statusCode: 429)
        case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
        }
      },
      withdraw: {
        switch try await api.withdrawHealthConsent() {
        case .noContent: return
        case .unauthorized: throw Failed(statusCode: 401)
        case .tooManyRequests: throw Failed(statusCode: 429)
        case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
        }
      })
  }

  public static var testValue: Self {
    Self(
      isGiven: {
        reportIssue("Unimplemented: @Dependency(\\.healthConsent).isGiven")
        return false
      },
      give: { reportIssue("Unimplemented: @Dependency(\\.healthConsent).give") },
      withdraw: { reportIssue("Unimplemented: @Dependency(\\.healthConsent).withdraw") })
  }
}

extension DependencyValues {
  public var healthConsent: HealthConsentClient {
    get { self[HealthConsentClient.self] }
    set { self[HealthConsentClient.self] = newValue }
  }
}
