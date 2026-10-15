import Dependencies
public import Foundation
import IssueReporting
import LilAPI

/// Uploads batch files through a background `URLSession`, so an upload finishes even if the app
/// is suspended in the middle of it. If the app is killed instead, the backfill uploads the
/// pending page again under the same batch IDs, which is safe.
public final class BackgroundUploads: NSObject, URLSessionDataDelegate, Sendable {
  public static let shared = BackgroundUploads()
  public static let sessionIdentifier = "tech.lil.health.uploads"

  private let waiting = LockIsolated<[Int: CheckedContinuation<Int, any Error>]>([:])
  private let finishedEvents = LockIsolated<(@Sendable () -> Void)?>(nil)
  private let session = LockIsolated<URLSession?>(nil)

  private var urlSession: URLSession {
    session.withValue { session in
      if let session { return session }
      let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
      configuration.isDiscretionary = false
      configuration.sessionSendsLaunchEvents = true
      let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      session = created
      return created
    }
  }

  /// Sends `request` with `file` as its body, and returns the response's status code.
  public func transfer(_ request: URLRequest, file: URL) async throws -> Int {
    let task = urlSession.uploadTask(with: request, fromFile: file)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting.withValue { $0[task.taskIdentifier] = continuation }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`: called once
  /// the session's events from the background are delivered.
  public func handleEvents(completion: @escaping @Sendable () -> Void) {
    finishedEvents.setValue(completion)
    _ = urlSession
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    // Uploads started before a relaunch have no one waiting; their pages are uploaded again.
    let continuation = waiting.withValue { $0.removeValue(forKey: task.taskIdentifier) }
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume(returning: (task.response as? HTTPURLResponse)?.statusCode ?? 0)
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion = finishedEvents.withValue {
      defer { $0 = nil }
      return $0
    }
    DispatchQueue.main.async { completion?() }
  }
}

extension HealthBatchUploader {
  /// Uploads with `transfer`, which sends a request and a file and returns the status code. A
  /// 401 marks the token rejected and tries once more with a refreshed one, since a background
  /// upload can start after its token expired.
  public static func uploading(
    to baseURL: URL,
    transfer: @escaping @Sendable (_ request: URLRequest, _ file: URL) async throws -> Int
  ) -> Self {
    Self { id, data in
      @Dependency(\.apiAuthentication) var authentication
      // Background sessions upload from files. Named uniquely, in case one batch is retried
      // while an earlier attempt is still around.
      let file = URL.temporaryDirectory.appending(
        path: "health-batch-\(id)-\(UUID().uuidString).ndjson.gz")
      try data.write(to: file, options: .atomic)
      defer { try? FileManager.default.removeItem(at: file) }
      for attempt in 0..<2 {
        guard let token = try await authentication.accessToken() else {
          throw Rejected(statusCode: 401)
        }
        var request = URLRequest(url: baseURL.appending(path: "v1/health/batches/\(id)"))
        request.httpMethod = "PUT"
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let status = try await transfer(request, file)
        if status == 202 { return }
        if status == 401, attempt == 0 {
          await authentication.rejected(token)
          continue
        }
        throw Rejected(statusCode: status)
      }
    }
  }
}
