import AuthenticationServices
import ConcurrencyExtras
import Foundation
import Testing

@testable import LilAuth

struct WebAuthenticationTests {
  /// AuthenticationServices calls the handler on its own XPC queue. A main-actor-isolated
  /// handler trapped there (851-2693), which this would too.
  @Test
  func theCompletionHandlerRunsOffTheMainThread() async {
    let results = LockIsolated<[Result<URL, BrowserAuthorizationError>]>([])
    let handler = browserCompletion(service: "Google") { result in
      results.withValue { $0.append(result) }
    }
    let callback = URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=c")!
    await withCheckedContinuation { done in
      DispatchQueue(label: "test.xpc-reply").async {
        #expect(!Thread.isMainThread)
        handler(callback, nil)
        handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
        handler(nil, nil)
        done.resume()
      }
    }
    #expect(
      results.value == [
        .success(callback), .failure(.canceled), .failure(.failed("Google didn't answer")),
      ])
  }
}
