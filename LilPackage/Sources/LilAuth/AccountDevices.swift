public import Dependencies
import Foundation
import IssueReporting
import LilAPI

/// The other installs signed in to the account, from `GET /v1/me`.
public struct AccountDevices: Sendable {
  /// How many other devices are signed in to the account with this app (`authDevice.app`).
  public var otherInstallsOfThisApp: @Sendable () async throws -> Int

  public init(otherInstallsOfThisApp: @escaping @Sendable () async throws -> Int) {
    self.otherInstallsOfThisApp = otherInstallsOfThisApp
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
        return try ok.body.json.devices.count { $0.app == device.app && !$0.current }
      case .unauthorized: throw Failed(statusCode: 401)
      case .tooManyRequests: throw Failed(statusCode: 429)
      case .undocumented(let statusCode, _): throw Failed(statusCode: statusCode)
      }
    }
  }

  public static let previewValue = Self { 0 }

  public static var testValue: Self {
    Self {
      reportIssue("Unimplemented: @Dependency(\\.accountDevices).otherInstallsOfThisApp")
      return 0
    }
  }
}

extension DependencyValues {
  public var accountDevices: AccountDevices {
    get { self[AccountDevices.self] }
    set { self[AccountDevices.self] = newValue }
  }
}
