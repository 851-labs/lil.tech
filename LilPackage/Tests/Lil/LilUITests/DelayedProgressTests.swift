import Dependencies
import LilTestSupport
import LilUI
import Testing

/// `DelayedProgress`'s schedule (851-3086): a spinner shows once a load has run for the delay,
/// then for at least the minimum time, on a `ManualClock`.
@MainActor
@Suite struct DelayedProgressTests {
  let clock = ManualClock()
  let timing = DelayedProgressTiming.standard

  func makeProgress(
    isLoading: Bool = false, timing: DelayedProgressTiming = .standard
  ) -> DelayedProgress {
    withDependencies {
      $0.continuousClock = clock
      $0.delayedProgressTiming = timing
    } operation: {
      DelayedProgress(isLoading: isLoading)
    }
  }

  /// Lets the tasks a clock advance woke run.
  func settle() async {
    for _ in 0..<10 { await Task.yield() }
  }

  @Test func standardTiming() {
    #expect(timing.delay == .milliseconds(200))
    #expect(timing.minimumVisible == .milliseconds(400))
  }

  @Test func neverShownWhenLoadingEndsWithinTheDelay() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: .milliseconds(199))
    await settle()
    #expect(!progress.isVisible)

    progress.update(isLoading: false)
    clock.advance(by: .seconds(1))
    await settle()
    #expect(!progress.isVisible)
    #expect(!clock.isAsleep(dueWithin: .seconds(60)))
  }

  @Test func shownAfterTheDelay() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    #expect(!progress.isVisible)

    clock.advance(by: timing.delay)
    try await eventually { progress.isVisible }
  }

  @Test func keptForTheMinimumTime() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: timing.delay)
    try await eventually { progress.isVisible }
    try await clock.waitUntilAsleep(endingIn: timing.minimumVisible)

    // Loaded 100 ms after it showed: it stays until 400 ms have passed.
    clock.advance(by: .milliseconds(100))
    progress.update(isLoading: false)
    #expect(progress.isVisible)
    clock.advance(by: .milliseconds(299))
    await settle()
    #expect(progress.isVisible)

    clock.advance(by: .milliseconds(1))
    try await eventually { !progress.isVisible }
  }

  @Test func hiddenAtOnceWhenLoadingEndsAfterTheMinimumTime() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: timing.delay)
    try await eventually { progress.isVisible }
    try await clock.waitUntilAsleep(endingIn: timing.minimumVisible)
    clock.advance(by: .seconds(2))
    await settle()
    #expect(progress.isVisible)

    progress.update(isLoading: false)
    #expect(!progress.isVisible)
  }

  @Test func aLoadThatStartsAgainWithinTheDelayWaitsAgain() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: .milliseconds(150))
    progress.update(isLoading: false)
    progress.update(isLoading: true)
    // The new load's delay, from now, not the first one's.
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: .milliseconds(150))
    await settle()
    #expect(!progress.isVisible)

    clock.advance(by: .milliseconds(50))
    try await eventually { progress.isVisible }
  }

  @Test func aLoadThatStartsAgainWithinTheMinimumTimeKeepsItShowing() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: timing.delay)
    try await eventually { progress.isVisible }
    try await clock.waitUntilAsleep(endingIn: timing.minimumVisible)

    // Off and on again within the minimum time, as a held ⌘← does: it never blinks off.
    for _ in 0..<3 {
      clock.advance(by: .milliseconds(50))
      progress.update(isLoading: false)
      #expect(progress.isVisible)
      progress.update(isLoading: true)
      #expect(progress.isVisible)
    }
    clock.advance(by: timing.minimumVisible)
    await settle()
    #expect(progress.isVisible)

    progress.update(isLoading: false)
    #expect(!progress.isVisible)
    #expect(!clock.isAsleep(dueWithin: .seconds(60)))
  }

  @Test func aRepeatedUpdateChangesNothing() async throws {
    let progress = makeProgress()
    progress.update(isLoading: true)
    try await clock.waitUntilAsleep(endingIn: timing.delay)
    clock.advance(by: .milliseconds(100))
    progress.update(isLoading: true)
    clock.advance(by: .milliseconds(100))
    try await eventually { progress.isVisible }
  }

  @Test func immediateTimingShowsAtOnce() {
    let loading = makeProgress(isLoading: true, timing: .immediate)
    #expect(loading.isVisible)
    loading.update(isLoading: false)
    #expect(!loading.isVisible)
    loading.update(isLoading: true)
    #expect(loading.isVisible)

    let idle = makeProgress(isLoading: false, timing: .immediate)
    #expect(!idle.isVisible)
    #expect(!clock.isAsleep(dueWithin: .seconds(60)))
  }

  @Test func standardTimingStartsHidden() {
    let progress = makeProgress(isLoading: true)
    #expect(!progress.isVisible)
    #expect(!clock.isAsleep(dueWithin: .seconds(60)))
  }
}
