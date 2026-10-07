public import Dependencies
public import Foundation
public import SQLiteData
import Synchronization

/// Read-only access to the Messages database (`~/Library/Messages/chat.db`).
///
/// Messages.app keeps writing to `chat.db` while we read it, so we only ever open it read-only.
/// Opening fails until the app has Full Disk Access, and is retried on every call until it
/// succeeds.
public struct ChatDatabase: Sendable {
  public var reader: @Sendable () throws -> any DatabaseReader

  public init(reader: @escaping @Sendable () throws -> any DatabaseReader) {
    self.reader = reader
  }
}

public struct ChatDatabaseUnavailable: Error, Sendable {
  public var url: URL
  public var underlyingError: any Error

  public init(url: URL, underlyingError: any Error) {
    self.url = url
    self.underlyingError = underlyingError
  }
}

extension ChatDatabase {
  public static let defaultURL = URL.homeDirectory.appending(path: "Library/Messages/chat.db")

  public static func live(url: URL = defaultURL) -> Self {
    let openedReader = Mutex<(any DatabaseReader)?>(nil)
    return Self {
      try openedReader.withLock { openedReader in
        if let openedReader {
          return openedReader
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "chat.db"
        do {
          let reader = try DatabaseQueue(
            path: url.path(percentEncoded: false), configuration: configuration)
          openedReader = reader
          return reader
        } catch {
          throw ChatDatabaseUnavailable(url: url, underlyingError: error)
        }
      }
    }
  }

  public static func constant(_ reader: any DatabaseReader) -> Self {
    Self { reader }
  }
}

extension ChatDatabase: DependencyKey {
  public static var liveValue: Self {
    .live()
  }

  public static var testValue: Self {
    .constant(try! makeInMemoryChatDatabase())
  }

  public static var previewValue: Self {
    .constant(try! makeInMemoryChatDatabase())
  }
}

extension DependencyValues {
  public var chatDatabase: ChatDatabase {
    get { self[ChatDatabase.self] }
    set { self[ChatDatabase.self] = newValue }
  }
}
