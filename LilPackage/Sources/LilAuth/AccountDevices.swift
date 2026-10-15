public import Dependencies
import Foundation
import IssueReporting
import LilAPI

/// The other installs signed in to the account, from `GET /v1/me`.
public struct AccountDevices: Sendable {
  /// The names (`nil` if unknown) of the account's other devices running this app
  /// (`authDevice.app`).
  public var othersWithThisApp: @Sendable () async throws -> [String?]

  public init(othersWithThisApp: @escaping @Sendable () async throws -> [String?]) {
    self.othersWithThisApp = othersWithThisApp
  }

  public struct Failed: Error, Equatable {
    public let statusCode: Int
  }
}

extension AccountDevices: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    @Dependency(\.authDevice) var device
    return Self {
      switch try await api.me() {
      case .ok(let ok):
        return try ok.body.json.devices
          .filter { $0.app == device.app && !$0.current }
          .map(\.name)
      case .unauthorized: throw Failed(statusCode: 401)
      case .tooManyRequests: throw Failed(statusCode: 429)
      case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
      }
    }
  }

  public static let previewValue = Self { [] }

  public static var testValue: Self {
    Self {
      reportIssue("Unimplemented: @Dependency(\\.accountDevices).othersWithThisApp")
      return []
    }
  }
}

extension DependencyValues {
  public var accountDevices: AccountDevices {
    get { self[AccountDevices.self] }
    set { self[AccountDevices.self] = newValue }
  }
}
