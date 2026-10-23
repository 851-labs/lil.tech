public import Dependencies
public import SwiftUI

/// When a loading spinner shows (851-3086): only once a load has run for `delay`, as Apple's apps
/// do, so loads that finish sooner never flash one, and then for at least `minimumVisible`, so it
/// doesn't blink off as soon as it's on. `DelayedProgressView` and `delayedProgress(isLoading:)`
/// read it from `@Dependency(\.delayedProgressTiming)`, and their time from
/// `@Dependency(\.continuousClock)`.
public struct DelayedProgressTiming: Equatable, Sendable {
  public var delay: Duration
  public var minimumVisible: Duration

  public init(delay: Duration, minimumVisible: Duration) {
    self.delay = delay
    self.minimumVisible = minimumVisible
  }

  /// The apps': a spinner waits 200 ms, then stays at least 400 ms. Long enough that a page or a
  /// period read from the Mac's database, or a quick request, shows none; short enough that a
  /// slow one shows it before it seems stuck.
  public static let standard = Self(delay: .milliseconds(200), minimumVisible: .milliseconds(400))

  /// A spinner shows as soon as its load starts and goes as soon as it ends: state catalogs', so
  /// their loading states show it in the image they draw at once, and tests' by default, so a
  /// view in a test never sleeps on the test's unimplemented clock.
  public static let immediate = Self(delay: .zero, minimumVisible: .zero)

  /// Whether a spinner simply follows its load, with no time of its own (`immediate`).
  var followsLoad: Bool { delay <= .zero && minimumVisible <= .zero }

  /// How long a spinner takes to fade in, or out.
  static let fade: Double = 0.2
}

extension DelayedProgressTiming: DependencyKey {
  public static var liveValue: Self { .standard }
  public static var testValue: Self { .immediate }
}

extension DependencyValues {
  /// When loading spinners show (`DelayedProgressTiming`): state catalogs set `.immediate`.
  public var delayedProgressTiming: DelayedProgressTiming {
    get { self[DelayedProgressTiming.self] }
    set { self[DelayedProgressTiming.self] = newValue }
  }
}

/// Whether a loading spinner is showing, given whether its load is running (`update`), on
/// `DelayedProgressTiming`'s schedule: it shows once a load has run for the delay, then stays for
/// at least the minimum, and through any load that starts again meanwhile. The state of
/// `DelayedProgressView` and `delayedProgress(isLoading:)`.
@MainActor
@Observable
public final class DelayedProgress {
  /// Whether the spinner shows.
  public private(set) var isVisible: Bool

  @ObservationIgnored private var isLoading: Bool
  /// Whether the spinner is in its minimum time, which hides it when it ends if loading has.
  @ObservationIgnored private var isHolding = false
  /// The delay's sleep, or the minimum time's.
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let timing: DelayedProgressTiming

  /// Starts with no load running, or, with `immediate` timing, already showing for one that is.
  /// It starts nothing until `update`.
  public init(isLoading: Bool = false) {
    @Dependency(\.continuousClock) var clock
    @Dependency(\.delayedProgressTiming) var timing
    self.clock = clock
    self.timing = timing
    let showsAtOnce = isLoading && timing.followsLoad
    self.isVisible = showsAtOnce
    self.isLoading = showsAtOnce
  }

  isolated deinit {
    task?.cancel()
  }

  /// Says whether the load is running. A load that starts waits out the delay before showing the
  /// spinner, unless it's still showing from the last one; one that ends hides it, once it has
  /// shown for the minimum time.
  public func update(isLoading: Bool) {
    guard isLoading != self.isLoading else { return }
    self.isLoading = isLoading
    if isLoading {
      // Still showing from the last load, in its minimum time: it goes on through this one.
      guard !isVisible else { return }
      guard timing.delay > .zero else { return show() }
      task = Task { [weak self, clock, timing] in
        do { try await clock.sleep(for: timing.delay) } catch { return }
        // Cancelled after the sleep ended but before this ran: the load ended in time.
        guard !Task.isCancelled, let self, self.isLoading else { return }
        self.show()
      }
    } else if isVisible {
      // In its minimum time, the end of that hides it.
      if !isHolding { setVisible(false) }
    } else {
      // Ended within the delay: never shown.
      task?.cancel()
      task = nil
    }
  }

  private func show() {
    task = nil
    setVisible(true)
    guard timing.minimumVisible > .zero else { return }
    isHolding = true
    task = Task { [weak self, clock, timing] in
      do { try await clock.sleep(for: timing.minimumVisible) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.holdEnded()
    }
  }

  private func holdEnded() {
    task = nil
    isHolding = false
    if !isLoading { setVisible(false) }
  }

  private func setVisible(_ isVisible: Bool) {
    withAnimation(.easeInOut(duration: DelayedProgressTiming.fade)) {
      self.isVisible = isVisible
    }
  }
}

/// A loading spinner (`ProgressView`) that shows on `DelayedProgressTiming`'s schedule while
/// `isLoading` (851-3086): after a short delay, fading in, then for at least a minimum time. It's
/// always laid out, at a spinner's size, so nothing moves when it shows or hides. Style it as a
/// `ProgressView` (`.controlSize(.small)`).
///
/// - `DelayedProgressView(isLoading:)` beside or over content it doesn't replace: a page's
///   spinner while the next period loads, or the row loading a list's next page.
/// - `DelayedProgressView()` for a placeholder in a list or form that rows of their own replace
///   when they've loaded (a section's rows): it only waits out the delay, since its rows take its
///   place as soon as they're there.
/// - `delayedProgress(isLoading:)` for a placeholder whose place the content takes: a page, a
///   chart or a map.
///
/// A spinner for something the person just did, in place of the button they pressed (Revoke…,
/// Agree), is a plain `ProgressView`, shown at once: it's how the press shows it was taken.
public struct DelayedProgressView: View {
  let isLoading: Bool
  @State private var progress: DelayedProgress?
  @Dependency(\.delayedProgressTiming) private var timing

  public init(isLoading: Bool = true) {
    self.isLoading = isLoading
  }

  public var body: some View {
    DelayedSpinner(isVisible: progress?.isVisible ?? (isLoading && timing.followsLoad))
      .onChange(of: isLoading, initial: true) {
        progress.start(isLoading: isLoading)
      }
  }
}

extension View {
  /// Puts a loading spinner over the view, centered, on `DelayedProgressTiming`'s schedule, for
  /// a placeholder whose place the content takes when it has loaded: a page, a chart or a map
  /// (851-3086). The view's loading state draws its space only, and the spinner shows over it once
  /// the load has run for the delay. If the content arrives while the spinner is in its minimum
  /// time, it's hidden until that ends, then fades in as the spinner fades out.
  public func delayedProgress(isLoading: Bool) -> some View {
    modifier(DelayedProgressModifier(isLoading: isLoading))
  }
}

private struct DelayedProgressModifier: ViewModifier {
  let isLoading: Bool
  @State private var progress: DelayedProgress?
  @Dependency(\.delayedProgressTiming) private var timing

  func body(content: Content) -> some View {
    let isVisible = progress?.isVisible ?? (isLoading && timing.followsLoad)
    // Loaded, while the spinner finishes its minimum time.
    let hidesContent = isVisible && !isLoading
    content
      .opacity(hidesContent ? 0 : 1)
      .allowsHitTesting(!hidesContent)
      .accessibilityHidden(hidesContent)
      .overlay {
        DelayedSpinner(isVisible: isVisible)
      }
      .onChange(of: isLoading, initial: true) {
        progress.start(isLoading: isLoading)
      }
  }
}

extension DelayedProgress? {
  /// Makes the view's state the first time, as it appears, rather than each time the view is
  /// rebuilt, then says whether the load is running.
  @MainActor
  fileprivate mutating func start(isLoading: Bool) {
    if self == nil { self = DelayedProgress(isLoading: isLoading) }
    self?.update(isLoading: isLoading)
  }
}

/// A spinner, laid out whether it shows or not: a hidden one gives it its size, and the one that
/// shows is only there while it does, so a page doesn't keep a spinner turning out of sight.
private struct DelayedSpinner: View {
  let isVisible: Bool

  var body: some View {
    ProgressView()
      .hidden()
      .overlay {
        if isVisible {
          ProgressView()
            .transition(.opacity)
        }
      }
  }
}
