import Dependencies
import DependenciesTestSupport
import Foundation
import MessagesDatabase
import Testing

struct ChatDatabaseChangesTests {
  @MainActor
  @Test
  func debounceCoalescesBursts() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let (events, input) = AsyncStream.makeStream(of: Void.self)
      let output = debounce(events, for: .milliseconds(250), clock: clock)
      let count = LockIsolated(0)
      let task = Task {
        for await _ in output {
          count.withValue { $0 += 1 }
        }
      }

      input.yield()
      await Task.megaYield()
      await clock.advance(by: .milliseconds(100))
      input.yield()
      await Task.megaYield()
      await clock.advance(by: .milliseconds(200))
      #expect(count.value == 0)

      await clock.advance(by: .milliseconds(50))
      #expect(count.value == 1)

      input.yield()
      await Task.megaYield()
      await clock.advance(by: .milliseconds(250))
      #expect(count.value == 2)

      input.finish()
      await task.value
      #expect(count.value == 2)
    }
  }

  @MainActor
  @Test
  func debounceDeliversPendingEventWhenUpstreamFinishes() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let (events, input) = AsyncStream.makeStream(of: Void.self)
      let output = debounce(events, for: .milliseconds(250), clock: clock)
      let count = LockIsolated(0)
      let task = Task {
        for await _ in output {
          count.withValue { $0 += 1 }
        }
      }

      input.yield()
      await Task.megaYield()
      input.finish()
      await Task.megaYield()
      await clock.advance(by: .milliseconds(250))
      await task.value
      #expect(count.value == 1)
    }
  }

  @Test(.dependency(\.continuousClock, ContinuousClock()))
  func liveWatchesTheDatabaseFiles() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "chat.db")
    let walURL = directory.appending(path: "chat.db-wal")
    try Data().write(to: databaseURL)
    try Data().write(to: walURL)

    let changes = ChatDatabaseChanges.live(url: databaseURL, debounceInterval: .milliseconds(50))
    let count = LockIsolated(0)
    let task = Task {
      for await _ in changes.stream() {
        count.withValue { $0 += 1 }
      }
    }
    defer { task.cancel() }
    try await Task.sleep(for: .milliseconds(300))

    try Data("unrelated".utf8).write(to: directory.appending(path: "other.db-wal"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(count.value == 0)

    try append("change", to: walURL)
    try await waitUntil { count.value == 1 }
    #expect(count.value == 1)

    try FileManager.default.removeItem(at: walURL)
    try await waitUntil { count.value == 2 }
    #expect(count.value == 2)

    try Data("recreated".utf8).write(to: walURL)
    try await waitUntil { count.value == 3 }
    #expect(count.value == 3)

    try append("after reopening", to: walURL)
    try await waitUntil { count.value == 4 }
    #expect(count.value == 4)
  }
}

private func append(_ string: String, to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(string.utf8))
}

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
}
