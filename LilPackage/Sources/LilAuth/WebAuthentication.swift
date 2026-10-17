import AuthenticationServices
import Dependencies

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Opens Google's sign-in page for `request` in a browser sheet over the app's key window, until
/// Google redirects back. Cancelling the calling task closes the sheet.
@MainActor
func authorizeInBrowser(
  _ request: GoogleAuthorizationRequest
) async -> Result<URL, GoogleAuthorizationError> {
  await openInBrowser(request.url, until: request.callbackScheme, service: "Google").mapError {
    switch $0 {
    case .canceled: .canceled
    case .failed(let reason): .failed(reason)
    }
  }
}

/// Why a browser sheet closed without its callback.
enum BrowserAuthorizationError: Error, Equatable {
  case canceled
  case failed(String)
}

/// Opens `url` in a browser sheet over the app's key window, until it redirects to
/// `callbackScheme`, and returns that URL. `service` names whose page it is, for errors.
/// Cancelling the calling task closes the sheet.
@MainActor
func openInBrowser(
  _ url: URL, until callbackScheme: String, service: String
) async -> Result<URL, BrowserAuthorizationError> {
  let anchor = KeyWindowAnchor()
  let browser = BrowserSession()
  let continuation = LockIsolated<
    CheckedContinuation<Result<URL, BrowserAuthorizationError>, Never>?
  >(
    nil)
  // The session's handler and a failed start can both finish it, so only the first resumes.
  let finish = { @Sendable (result: Result<URL, BrowserAuthorizationError>) in
    continuation.withValue {
      $0?.resume(returning: result)
      $0 = nil
    }
  }
  return await withTaskCancellationHandler {
    await withCheckedContinuation { resume in
      continuation.setValue(resume)
      let started = ASWebAuthenticationSession(
        url: url, callback: .customScheme(callbackScheme)
      ) { url, error in
        if let url {
          finish(.success(url))
        } else if let error = error as? ASWebAuthenticationSessionError,
          error.code == .canceledLogin
        {
          finish(.failure(.canceled))
        } else {
          finish(.failure(.failed(error?.localizedDescription ?? "\(service) didn't answer")))
        }
      }
      started.presentationContextProvider = anchor
      browser.session = started
      if !started.start() {
        finish(.failure(.failed("Couldn't open \(service)'s sign-in page")))
      }
    }
  } onCancel: {
    Task { @MainActor in browser.session?.cancel() }
    finish(.failure(.canceled))
  }
}

/// The open browser sheet, so cancelling can close it.
@MainActor
private final class BrowserSession {
  var session: ASWebAuthenticationSession?
}

/// Presents the browser sheet over the app's key window.
private final class KeyWindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
          return window
        }
        return ASPresentationAnchor(windowScene: scenes.first!)
      #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
      #endif
    }
  }
}
