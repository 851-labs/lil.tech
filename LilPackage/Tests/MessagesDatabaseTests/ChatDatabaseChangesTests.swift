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
  func liveWatchesOnlyTheDatabaseFiles() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let changes = ChatDatabaseChanges.live(
      url: directory.appending(path: "chat.db"),
      debounceInterval: .milliseconds(50)
    )
    let count = LockIsolated(0)
    let task = Task {
      for await _ in changes.stream() {
        count.withValue { $0 += 1 }
      }
    }
    defer { task.cancel() }
    try await Task.sleep(for: .milliseconds(500))

    try Data("unrelated".utf8).write(to: directory.appending(path: "other.db-wal"))
    try await Task.sleep(for: .seconds(1))
    #expect(count.value == 0)

    try Data("change".utf8).write(to: directory.appending(path: "chat.db-wal"))
    for _ in 0..<50 where count.value == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(count.value == 1)
  }
}
