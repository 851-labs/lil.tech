import Dependencies
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
struct AccountDevicesTests {
  @Test
  func listsTheOtherInstallsOfThisApp() async throws {
    let me = """
      {"id":"usr_1","displayName":"Ada","identities":[],"devices":[
        {"id":"dev_1","app":"health-ios","platform":"ios","name":"Ada's iPhone","createdAt":1,"current":false},
        {"id":"dev_2","app":"health-ios","platform":"ios","name":null,"createdAt":2,"current":false},
        {"id":"dev_3","app":"health-ios","platform":"ios","name":null,"createdAt":3,"current":true},
        {"id":"dev_4","app":"health-mac","platform":"macos","name":"Ada's Mac","createdAt":4,"current":false},
        {"id":"dev_5","app":"health-ios","platform":"visionos","name":"Future","createdAt":5,"current":false}
      ]}
      """
    let devices = withDependencies {
      $0.authDevice = AuthDevice(app: "health-ios", platform: .ios, name: nil)
      $0.api = Client.mock { request, _ in
        #expect(request.path == "/v1/me")
        return (
          HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(me)
        )
      }
    } operation: {
      AccountDevices.liveValue
    }
    // Not this device, and not other apps. An unknown platform still decodes.
    #expect(try await devices.otherInstallsOfThisApp() == 3)
  }

  @Test
  func aRefusedRequestThrows() async {
    let devices = withDependencies {
      $0.api = Client.mock { _, _ in (HTTPResponse(status: .serviceUnavailable), nil) }
    } operation: {
      AccountDevices.liveValue
    }
    await #expect(throws: AccountDevices.Failed(statusCode: 503)) {
      try await devices.otherInstallsOfThisApp()
    }
  }
}
