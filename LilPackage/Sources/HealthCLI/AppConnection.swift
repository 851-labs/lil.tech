public import Foundation
import HealthAgentAccess
import Synchronization

#if canImport(AppKit)
  import AppKit
#endif

extension HealthCLI {
  /// How the action commands reach lil health for Mac (851-2896): whether it's running, waking
  /// it, launching it, and waiting. Live, the app found through Launch Services; tests answer
  /// requests themselves.
  public struct AppConnection: Sendable {
    /// Whether lil health is running.
    public var isRunning: @Sendable () -> Bool
    /// Wakes a running app to look for requests (`AgentActionSignal.post`).
    public var signal: @Sendable () -> Void
    /// Launches the app, or brings a running one forward, in front if `activate`. Throws
    /// `ActionError` when it isn't installed or can't be opened.
    public var open: @Sendable (_ activate: Bool) throws -> Void
    /// Waits between looks at the request.
    public var sleep: @Sendable (Duration) -> Void
    /// From now on, Ctrl-C stops waiting (`isInterrupted`) rather than ending the process.
    public var catchInterrupts: @Sendable () -> Void
    /// Whether Ctrl-C was pressed since `catchInterrupts`.
    public var isInterrupted: @Sendable () -> Bool

    public init(
      isRunning: @escaping @Sendable () -> Bool,
      signal: @escaping @Sendable () -> Void,
      open: @escaping @Sendable (_ activate: Bool) throws -> Void,
      sleep: @escaping @Sendable (Duration) -> Void = { duration in
        let (seconds, attoseconds) = duration.components
        Thread.sleep(forTimeInterval: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
      },
      catchInterrupts: @escaping @Sendable () -> Void = {},
      isInterrupted: @escaping @Sendable () -> Bool = { false }
    ) {
      self.isRunning = isRunning
      self.signal = signal
      self.open = open
      self.sleep = sleep
      self.catchInterrupts = catchInterrupts
      self.isInterrupted = isInterrupted
    }

    /// No app: not running, and not installed.
    public static let notInstalled = Self(
      isRunning: { false }, signal: {}, open: { _ in throw ActionError.notInstalled })
  }

  /// How long the action commands wait.
  public struct Timing: Sendable {
    /// For the app to claim a request: once it has, it's doing it. 15 s.
    public var claimWait: Duration
    /// For `sync` to finish once claimed: the app's own wait (`HealthAppActions.syncWait`,
    /// 60 s), then a little more for it to answer. The app answers first; this only stops a
    /// command waiting on an app that stopped answering. 75 s.
    public var syncWait: Duration
    /// For `open` to answer once claimed: the app's wait for sign-in after a launch
    /// (`HealthAppActions.signInWait`, 10 s), then a little more. 15 s.
    public var openWait: Duration
    /// Between looks at the request.
    public var pollInterval: Duration
    /// Between looks at an export the app has claimed, which can take minutes: the request's
    /// database isn't opened five times a second all that while.
    public var slowPollInterval: Duration

    public init(
      claimWait: Duration = .seconds(15), syncWait: Duration = .seconds(75),
      openWait: Duration = .seconds(15), pollInterval: Duration = .milliseconds(200),
      slowPollInterval: Duration = .seconds(1)
    ) {
      self.claimWait = claimWait
      self.syncWait = syncWait
      self.openWait = openWait
      self.pollInterval = pollInterval
      self.slowPollInterval = slowPollInterval
    }
  }
}

extension HealthCLI.ActionError {
  static let notInstalled = Self(
    "lil health isn't installed.", status: HealthCLI.Status.unavailable)
}

#if canImport(AppKit)
  extension HealthCLI.AppConnection {
    /// lil health's bundle ID, on the Mac. A Debug tool's is a Debug app's (851-3027), since only
    /// a Debug app reads the folders a Debug tool writes its requests to (`Servers/<server>`), so
    /// a Debug tool never launches or brings forward the installed app, nor a Release tool a Debug
    /// app. The signal still reaches both, which then find nothing in their own folder.
    #if DEBUG
      static let bundleIdentifier = "tech.lil.health.debug"
    #else
      static let bundleIdentifier = "tech.lil.health"
    #endif

    /// The environment a launched app gets from the command: where it reads (a test's home
    /// folder), so it finds the request where the command wrote it, and which server a Debug
    /// build talks to (release builds ignore it).
    static let forwardedVariables = ["CFFIXED_USER_HOME", "LIL_API_URL"]

    /// The running app, or else the one this tool is inside (`Contents/MacOS/lil-health`), or
    /// else the one Launch Services knows by its bundle ID, as `lil` finds it.
    public static func live(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
      let interrupted = Atomic(false)
      let interrupts = Mutex<(any DispatchSourceSignal)?>(nil)
      return Self(
        isRunning: { running() != nil },
        signal: { AgentActionSignal.post() },
        open: { activate in
          guard
            let url = running()?.bundleURL ?? enclosingApp()
              ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
          else { throw HealthCLI.ActionError.notInstalled }
          let configuration = NSWorkspace.OpenConfiguration()
          configuration.activates = activate
          configuration.addsToRecentItems = false
          configuration.environment = environment.filter { forwardedVariables.contains($0.key) }
          let failure = Mutex<(any Error)?>(nil)
          let done = DispatchSemaphore(value: 0)
          NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            failure.withLock { $0 = error }
            done.signal()
          }
          done.wait()
          if let error = failure.withLock({ $0 }) {
            throw HealthCLI.ActionError(
              "Couldn't open lil health: \(error.localizedDescription)",
              status: HealthCLI.Status.unavailable)
          }
        },
        catchInterrupts: {
          interrupts.withLock { source in
            guard source == nil else { return }
            Darwin.signal(SIGINT, SIG_IGN)
            let new = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            new.setEventHandler { interrupted.store(true, ordering: .sequentiallyConsistent) }
            new.resume()
            source = new
          }
        },
        isInterrupted: { interrupted.load(ordering: .sequentiallyConsistent) }
      )
    }

    private static func running() -> NSRunningApplication? {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first { !$0.isTerminated }
    }

    /// The app bundle this tool is in, if it's lil health's.
    private static func enclosingApp() -> URL? {
      guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        return nil
      }
      let app = executable.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      guard app.pathExtension == "app",
        Bundle(url: app)?.bundleIdentifier == bundleIdentifier
      else { return nil }
      return app
    }
  }
#endif
