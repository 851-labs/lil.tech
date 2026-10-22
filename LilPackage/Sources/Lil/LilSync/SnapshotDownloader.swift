public import Dependencies
public import Foundation

extension DependencyValues {
  /// Downloads snapshot parts for ``LilSyncEngine``.
  public var snapshotDownloader: SnapshotDownloader {
    get { self[SnapshotDownloader.self] }
    set { self[SnapshotDownloader.self] = newValue }
  }
}

/// Downloads one snapshot part from a manifest's signed URL, which needs no `Authorization`
/// header. The live value uses a default `URLSession`, which suits the Mac, the device that
/// bootstraps; an app can set one built on a background session.
public struct SnapshotDownloader: Sendable {
  public var download: @Sendable (_ url: URL) async throws -> Data

  public init(download: @escaping @Sendable (_ url: URL) async throws -> Data) {
    self.download = download
  }

  /// The part URL expired, or its snapshot is gone; the manifest needs refreshing.
  public struct Expired: Error, Equatable {
    public init() {}
  }

  public struct Failed: Error, Equatable {
    public let statusCode: Int
    public init(statusCode: Int) { self.statusCode = statusCode }
  }
}

extension SnapshotDownloader: DependencyKey {
  public static var liveValue: Self {
    Self { url in
      let (data, response) = try await URLSession.shared.data(from: url)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200: return data
      case 401, 404: throw Expired()
      default: throw Failed(statusCode: status)
      }
    }
  }
  public static var testValue: Self {
    Self { url in
      reportIssue("Unimplemented: @Dependency(\\.snapshotDownloader) for \(url)")
      throw Failed(statusCode: 0)
    }
  }
}
