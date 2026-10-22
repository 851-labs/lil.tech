public import Dependencies
public import Foundation
import IssueReporting
import LilAPI

/// A data export of the account (`POST /v1/me/exports`): everything it holds, as one archive.
public struct DataExport: Equatable, Sendable {
  public var requestedAt: Date
  /// Downloads the archive, once it's ready. Short-lived: ask for the export again for a new one.
  public var url: URL?

  public init(requestedAt: Date, url: URL?) {
    self.requestedAt = requestedAt
    self.url = url
  }

  init(_ export: Components.Schemas.DataExport) {
    self.init(
      requestedAt: Date(timeIntervalSince1970: TimeInterval(export.requestedAt) / 1000),
      url: export.ready ? export.url.flatMap(URL.init(string:)) : nil)
  }
}

/// How a download of an export's archive is going.
public enum DataExportDownload: Equatable, Sendable {
  /// The share of the archive downloaded, from 0 to 1.
  case progress(Double)
  /// Downloaded to `file`, a temporary file the caller moves, with the archive's name.
  case finished(file: URL, name: String)
}

/// Why exporting didn't work, worded for account settings.
public enum DataExportError: Error, Equatable, Sendable {
  /// It isn't possible right now; try again later.
  case unavailable
  /// The session ended.
  case signedOut
  /// The download URL stopped working (it expired, or the export was replaced): ask again.
  case expired
  /// The account holds more than one archive can.
  case tooLarge
  case failed(String)

  public var message: String {
    switch self {
    case .unavailable: "Exporting isn't possible right now. Please try again later."
    case .signedOut: "Your session ended. Sign in again."
    case .expired: "The export's link expired. Please try again."
    case .tooLarge:
      "Your account holds too much to export in one archive. Please contact hello@851.sh."
    case .failed(let reason): "Exporting didn't work: \(reason)"
    }
  }
}

/// Asking for a data export, checking on it, and downloading its archive.
public struct DataExportClient: Sendable {
  /// Asks for an export, or gets the one asked for within the last day.
  public var request: @Sendable () async throws(DataExportError) -> DataExport
  /// The latest export asked for, if any.
  public var latest: @Sendable () async throws(DataExportError) -> DataExport?
  /// Downloads an export's archive, reporting progress, then where it is.
  public var download: @Sendable (_ url: URL) -> AsyncThrowingStream<DataExportDownload, any Error>

  public init(
    request: @escaping @Sendable () async throws(DataExportError) -> DataExport,
    latest: @escaping @Sendable () async throws(DataExportError) -> DataExport?,
    download:
      @escaping @Sendable (_ url: URL) -> AsyncThrowingStream<DataExportDownload, any Error>
  ) {
    self.request = request
    self.latest = latest
    self.download = download
  }
}

extension DataExportClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    /// Calls an endpoint, turning a failed request into ``DataExportError``.
    @Sendable func call<Output>(
      _ request: @Sendable () async throws -> Output
    ) async throws(DataExportError) -> Output {
      do {
        return try await request()
      } catch {
        throw .failed(error.localizedDescription)
      }
    }
    return Self(
      request: { () throws(DataExportError) in
        switch try await call({ try await api.requestExport() }) {
        case .ok(let ok):
          guard let export = try? ok.body.json else { throw .failed("Unexpected response") }
          return DataExport(export)
        case .unauthorized: throw .signedOut
        case .serviceUnavailable, .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      latest: { () throws(DataExportError) in
        switch try await call({ try await api.latestExport() }) {
        case .ok(let ok):
          guard let export = try? ok.body.json else { throw .failed("Unexpected response") }
          return DataExport(export)
        case .notFound: return nil
        case .unauthorized: throw .signedOut
        case .serviceUnavailable, .tooManyRequests: throw .unavailable
        case .undocumented(let statusCode, _): throw .failed("HTTP \(statusCode)")
        }
      },
      download: { url in
        AsyncThrowingStream { continuation in
          let task = URLSession.shared.downloadTask(with: url) { file, response, error in
            if let error {
              continuation.finish(throwing: error)
              return
            }
            guard let file, let response = response as? HTTPURLResponse,
              response.statusCode == 200
            else {
              let status = (response as? HTTPURLResponse)?.statusCode ?? 0
              let error: DataExportError =
                switch status {
                case 401, 410: .expired
                case 507: .tooLarge
                default: .failed("HTTP \(status)")
                }
              continuation.finish(throwing: error)
              return
            }
            // The system deletes `file` when this returns, so it moves somewhere it keeps.
            let kept = FileManager.default.temporaryDirectory
              .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            do {
              try FileManager.default.moveItem(at: file, to: kept)
            } catch {
              continuation.finish(throwing: error)
              return
            }
            continuation.yield(
              .finished(file: kept, name: response.suggestedFilename ?? "lil-export.tar"))
            continuation.finish()
          }
          // A whole percent at a time: a big archive changes it for every chunk received.
          let percent = LockIsolated(-1)
          let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let now = Int(progress.fractionCompleted * 100)
            let changed = percent.withValue { last in
              defer { last = now }
              return now != last
            }
            if changed { continuation.yield(.progress(Double(now) / 100)) }
          }
          continuation.onTermination = { _ in
            observation.invalidate()
            task.cancel()
          }
          task.resume()
        }
      }
    )
  }

  public static var testValue: Self {
    Self(
      request: { () throws(DataExportError) in
        reportIssue("Unimplemented: @Dependency(\\.dataExports).request")
        throw .unavailable
      },
      latest: { () throws(DataExportError) in
        reportIssue("Unimplemented: @Dependency(\\.dataExports).latest")
        return nil
      },
      download: { _ in
        reportIssue("Unimplemented: @Dependency(\\.dataExports).download")
        return AsyncThrowingStream { $0.finish() }
      }
    )
  }
}

extension DependencyValues {
  /// The account's data exports.
  public var dataExports: DataExportClient {
    get { self[DataExportClient.self] }
    set { self[DataExportClient.self] = newValue }
  }
}
