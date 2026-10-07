import CoreServices
public import Dependencies
public import Foundation

/// Notifies when Messages.app writes to `chat.db`.
///
/// SQLite observation only sees writes made through our own connection, so we watch the files
/// instead. Messages writes to `chat.db-wal` on every change and to `chat.db` on checkpoints, often
/// in bursts, so events are debounced before they're delivered.
public struct ChatDatabaseChanges: Sendable {
  public var stream: @Sendable () -> AsyncStream<Void>

  public init(stream: @escaping @Sendable () -> AsyncStream<Void>) {
    self.stream = stream
  }
}

extension ChatDatabaseChanges {
  public static func live(
    url: URL = ChatDatabase.defaultURL,
    debounceInterval: Duration = .milliseconds(250)
  ) -> Self {
    Self {
      @Dependency(\.continuousClock) var clock
      let fileNames: Set = [url.lastPathComponent, url.lastPathComponent + "-wal"]
      return debounce(
        fileSystemEvents(in: url.deletingLastPathComponent(), fileNames: fileNames),
        for: debounceInterval,
        clock: clock
      )
    }
  }
}

extension ChatDatabaseChanges: DependencyKey {
  public static var liveValue: Self {
    .live()
  }

  public static var testValue: Self {
    Self(
      stream: unimplemented("ChatDatabaseChanges.stream", placeholder: AsyncStream { $0.finish() }))
  }

  public static var previewValue: Self {
    Self { AsyncStream { _ in } }
  }
}

extension DependencyValues {
  public var chatDatabaseChanges: ChatDatabaseChanges {
    get { self[ChatDatabaseChanges.self] }
    set { self[ChatDatabaseChanges.self] = newValue }
  }
}

/// Delivers one event after `interval` has passed without any new upstream events.
public func debounce(
  _ events: AsyncStream<Void>,
  for interval: Duration,
  clock: any Clock<Duration>
) -> AsyncStream<Void> {
  AsyncStream { continuation in
    let task = Task {
      var pending: Task<Void, Never>?
      for await _ in events {
        pending?.cancel()
        pending = Task {
          do {
            try await clock.sleep(for: interval)
          } catch {
            return
          }
          continuation.yield()
        }
      }
      await pending?.value
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

private func fileSystemEvents(in directory: URL, fileNames: Set<String>) -> AsyncStream<Void> {
  AsyncStream { continuation in
    let box = Unmanaged.passRetained(EventsBox(continuation: continuation, fileNames: fileNames))
    var context = FSEventStreamContext(
      version: 0,
      info: box.toOpaque(),
      retain: nil,
      release: { Unmanaged<EventsBox>.fromOpaque($0!).release() },
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      let box = Unmanaged<EventsBox>.fromOpaque(info!).takeUnretainedValue()
      let paths = unsafeBitCast(paths, to: NSArray.self)
      for case let path as String in paths.prefix(count)
      where box.fileNames.contains((path as NSString).lastPathComponent) {
        box.continuation.yield()
        return
      }
    }
    guard
      let stream = FSEventStreamCreate(
        nil,
        callback,
        &context,
        [directory.path(percentEncoded: false)] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.05,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        )
      )
    else {
      box.release()
      continuation.finish()
      return
    }
    let eventStream = EventStream(rawValue: stream)
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "tech.lil.chat-database-changes"))
    FSEventStreamStart(stream)
    continuation.onTermination = { _ in
      FSEventStreamStop(eventStream.rawValue)
      FSEventStreamInvalidate(eventStream.rawValue)
      FSEventStreamRelease(eventStream.rawValue)
    }
  }
}

private final class EventsBox: Sendable {
  let continuation: AsyncStream<Void>.Continuation
  let fileNames: Set<String>

  init(continuation: AsyncStream<Void>.Continuation, fileNames: Set<String>) {
    self.continuation = continuation
    self.fileNames = fileNames
  }
}

private struct EventStream: @unchecked Sendable {
  let rawValue: FSEventStreamRef
}
