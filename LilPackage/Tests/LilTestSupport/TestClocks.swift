public import Dependencies
public import Foundation
public import Testing

/// An immediate clock that records how long each sleep was for, and runs `onSleep` during it. The
/// first `immediateSleeps` sleeps return at once; later ones suspend until cancelled. Not
/// `ImmediateClock` itself: its sleeps wait on background-priority tasks, which tests that spin
/// waiting for a state can starve when they run alongside.
public final class RecordingClock: Clock, Sendable {
  public typealias Instant = ImmediateClock<Duration>.Instant

  private let immediateSleeps: Int
  private let onSleep: @Sendable (Duration) async -> Void
  private let current = LockIsolated(Instant())
  public let sleeps = LockIsolated<[Duration]>([])

  public init(
    immediateSleeps: Int = .max, onSleep: @escaping @Sendable (Duration) async -> Void = { _ in }
  ) {
    self.immediateSleeps = immediateSleeps
    self.onSleep = onSleep
  }

  public var now: Instant { current.value }
  public var minimumResolution: Duration { .zero }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    let duration = now.duration(to: deadline)
    let count = sleeps.withValue {
      $0.append(duration)
      return $0.count
    }
    if count > immediateSleeps {
      try await Task.sleep(for: .seconds(3600))
    }
    await onSleep(duration)
    try Task.checkCancellation()
    current.withValue { $0 = max($0, deadline) }
    await Task.yield()
  }
}

/// A clock that tests move on by hand, like `TestClock`, but that can wait until the code under
/// test is asleep: advancing a `TestClock` before then is missed, and the sleep never ends.
/// Unlike `TestClock`, an advance goes straight to its end, so a sleep started by a task it wakes
/// counts from there.
public final class ManualClock: Clock, Sendable {
  public typealias Instant = ImmediateClock<Duration>.Instant

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant()
    var sleepers: [Sleeper] = []
    /// Sleeps cancelled while not waiting: before they started (then they end at once), or after
    /// they ended (harmless).
    var cancelled: Set<UUID> = []
  }

  private let state = LockIsolated(State())

  public init() {}

  public var now: Instant { state.value.now }
  public var minimumResolution: Duration { .zero }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = state.withValue { state in
          if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
          if deadline <= state.now { return .success(()) }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let sleeper = state.withValue { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
          state.cancelled.insert(id)
          return nil
        }
        return state.sleepers.remove(at: index)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Whether a sleep that ends within `duration` from now is in progress.
  public func isAsleep(dueWithin duration: Duration) -> Bool {
    let state = state.value
    return state.sleepers.contains { $0.deadline <= state.now.advanced(by: duration) }
  }

  public struct NeverAsleep: Error {}

  /// Waits until a sleep that ends within `duration` from now is in progress. Throws if none
  /// starts, so the test stops there rather than going on in the wrong state.
  public func waitUntilAsleep(
    dueWithin duration: Duration, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    try await eventually({ isAsleep(dueWithin: duration) }, sourceLocation: sourceLocation)
    guard isAsleep(dueWithin: duration) else { throw NeverAsleep() }
  }

  /// Waits until a sleep that ends exactly `duration` from now is in progress, e.g. one that
  /// replaced an earlier sleep still due sooner. Throws if none starts.
  public func waitUntilAsleep(
    endingIn duration: Duration, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let isAsleep = {
      let state = self.state.value
      return state.sleepers.contains { $0.deadline == state.now.advanced(by: duration) }
    }
    try await eventually(isAsleep, sourceLocation: sourceLocation)
    guard isAsleep() else { throw NeverAsleep() }
  }

  /// Moves time on by `duration`, ending the sleeps that are due.
  public func advance(by duration: Duration) {
    let due = state.withValue { state in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      let due = state.sleepers.filter { $0.deadline <= now }
      state.sleepers.removeAll { $0.deadline <= now }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Waits for `condition`, which other tasks make true, yielding in between. Bounded by time
/// rather than a number of yields, so a busy machine (e.g. the pre-commit hook building the apps
/// alongside) doesn't make it give up early.
public func eventually(
  _ condition: () throws -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  while ContinuousClock.now < deadline {
    if try condition() { return }
    await Task.yield()
    if try condition() { return }
    // A pause rather than spinning, which would take the CPU from the tasks being waited on.
    try await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("Condition never became true", sourceLocation: sourceLocation)
}
