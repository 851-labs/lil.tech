public import Dependencies
public import Foundation

/// Notifies when Messages.app writes to `chat.db`.
///
/// SQLite observation only sees writes made through our own connection, so we watch the files
/// instead. Messages writes to `chat.db-wal` on every change and to `chat.db` on checkpoints, often
/// in bursts, so events are debounced before they're delivered.
///
/// Files are watched with kqueue vnode events rather than FSEvents: FSEvents doesn't deliver events
/// for `~/Library/Messages`, which is a privacy-protected location.
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
      let walURL = url.deletingLastPathComponent().appending(path: url.lastPathComponent + "-wal")
      return debounce(
        fileChanges(at: [url, walURL]),
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

private func fileChanges(at urls: [URL]) -> AsyncStream<Void> {
  AsyncStream { continuation in
    let queue = DispatchQueue(label: "tech.lil.chat-database-changes")
    let watchers = urls.map { url in
      FileWatcher(url: url, queue: queue) { continuation.yield() }
    }
    queue.async {
      for watcher in watchers {
        watcher.start()
      }
    }
    continuation.onTermination = { _ in
      queue.async {
        for watcher in watchers {
          watcher.stop()
        }
      }
    }
  }
}

/// Watches a single file with a kqueue vnode source, reopening it whenever it's deleted, renamed,
/// or doesn't exist yet.
private final class FileWatcher: @unchecked Sendable {
  private let url: URL
  private let queue: DispatchQueue
  private let onChange: @Sendable () -> Void
  // Only accessed on `queue`.
  private var source: (any DispatchSourceFileSystemObject)?
  private var isStopped = false

  init(url: URL, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
    self.url = url
    self.queue = queue
    self.onChange = onChange
  }

  func start(isReopening: Bool = false) {
    guard !isStopped else { return }
    let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
    guard descriptor >= 0 else {
      scheduleReopen()
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .delete, .rename, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self, unowned source] in
      guard let self else { return }
      onChange()
      if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
        source.cancel()
        self.source = nil
        scheduleReopen()
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()
    self.source = source
    if isReopening {
      onChange()
    }
  }

  func stop() {
    isStopped = true
    source?.cancel()
    source = nil
  }

  private func scheduleReopen() {
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.start(isReopening: true)
    }
  }
}
