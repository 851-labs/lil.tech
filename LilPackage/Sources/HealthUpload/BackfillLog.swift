import Foundation
import OSLog

/// What the backfill did and how long each step took, in a file next to its state, so a stall
/// on a device can be read off it (`devicectl device copy from`, `HealthBackfill/diagnostics.log`)
/// and in the device's log (`subsystem: tech.lil.health`, category `Backfill`). Type names,
/// counts and timings only: never Health values.
///
/// Off until the app turns it on, so tests and previews write nothing.
public enum BackfillLog {
  public static let isEnabled = LockIsolatedFlag()

  static let logger = Logger(subsystem: "tech.lil.health", category: "Backfill")
  private static let queue = DispatchQueue(label: "tech.lil.health.backfill-log")
  /// Past this, the file starts over, keeping the previous one as `diagnostics.1.log`.
  static let maxBytes = 512 * 1024

  static var file: URL {
    URL.applicationSupportDirectory.appending(path: "HealthBackfill/diagnostics.log")
  }

  /// Logs `message`, with the time.
  public static func write(_ message: String) {
    guard isEnabled.value else { return }
    logger.notice("\(message, privacy: .public)")
    let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
    queue.async {
      let manager = FileManager.default
      let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
      if size > maxBytes {
        let previous = file.deletingLastPathComponent().appending(path: "diagnostics.1.log")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: file, to: previous)
      }
      if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
      } else {
        try? manager.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: file)
      }
    }
  }

  /// Seconds since `start`, for messages.
  static func since(_ start: ContinuousClock.Instant) -> String {
    let duration = ContinuousClock.now - start
    return (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
      .formatted(.number.precision(.fractionLength(2))) + "s"
  }

  /// A short name for a type: `HKQuantityTypeIdentifierStepCount` reads `StepCount`.
  static func name(_ type: String) -> String {
    type.components(separatedBy: "Identifier").last.flatMap { $0.isEmpty ? nil : $0 } ?? type
  }
}

/// A flag safe to read from any thread.
public final class LockIsolatedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  public var value: Bool {
    lock.withLock { flag }
  }

  public func set(_ value: Bool) {
    lock.withLock { flag = value }
  }
}
