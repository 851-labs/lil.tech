import Dependencies
import Foundation
import HTTPTypes
import LilAPI
import OpenAPIRuntime
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
struct SignInMethodsClientTests {
  private func client(
    _ answer: @escaping @Sendable (HTTPRequest, String?) -> (HTTPResponse.Status, String?)
  ) -> SignInMethodsClient {
    withDependencies {
      $0.api = Client.mock { request, body in
        let text: String? =
          if let body { try await String(collecting: body, upTo: 1 << 16) } else { nil }
        let (status, json) = answer(request, text)
        return (
          HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
          json.map { HTTPBody($0) }
        )
      }
    } operation: {
      SignInMethodsClient.liveValue
    }
  }

  @Test
  func listsTheAccountsIdentities() async throws {
    let methods = client { request, _ in
      #expect(request.path == "/v1/me")
      return (
        .ok,
        """
        {"id":"usr_1","displayName":null,"devices":[],"identities":[
          {"id":"idt_1","provider":"apple","email":null},
          {"id":"idt_2","provider":"google","email":"ada@example.com"}
        ]}
        """
      )
    }
    #expect(
      try await methods.list() == [
        SignInMethod(id: "idt_1", provider: .apple, email: nil),
        SignInMethod(id: "idt_2", provider: .google, email: "ada@example.com"),
      ])
  }

  @Test
  func linksGoogle() async throws {
    let methods = client { request, body in
      #expect(request.method == .post)
      #expect(request.path == "/v1/me/identities/google")
      let payload = body.flatMap {
        try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
      }
      #expect(payload == ["idToken": "google-id-token", "nonce": "nonce"])
      return (.ok, #"{"id":"idt_2","provider":"google","email":"ada@example.com"}"#)
    }
    #expect(
      try await methods.linkGoogle("google-id-token", "nonce")
        == SignInMethod(id: "idt_2", provider: .google, email: "ada@example.com"))
  }

  @Test
  func linkingAnotherUsersAccountIsRefused() async {
    let methods = client { _, _ in
      (.conflict, #"{"_tag":"IdentityInUse","message":"taken"}"#)
    }
    await #expect(throws: SignInMethodError.inUse(.apple)) {
      try await methods.linkApple(AppleCredential(identityToken: "apple-token"), "nonce")
    }
  }

  @Test
  func unlinkingTheLastMethodIsRefused() async {
    let methods = client { request, _ in
      #expect(request.method == .delete)
      #expect(request.path == "/v1/me/identities/idt_1")
      return (.conflict, #"{"_tag":"LastIdentity","message":"last"}"#)
    }
    await #expect(throws: SignInMethodError.lastMethod) {
      try await methods.unlink("idt_1")
    }
  }

  @Test
  func unlinkingOneAlreadyGoneIsDone() async throws {
    let methods = client { _, _ in (.notFound, #"{"_tag":"IdentityNotFound","message":"gone"}"#) }
    try await methods.unlink("idt_1")
  }
}
