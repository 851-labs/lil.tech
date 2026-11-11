public import Dependencies
import Foundation
import OSLog

/// What the backfill did and how long each step took, in a file next to its state, so a stall
/// on a device can be read off it (`devicectl device copy from`, `HealthBackfill/diagnostics.log`)
/// and in the device's log (`subsystem: tech.lil.health`, category `Backfill`). Type names,
/// counts and timings only: never Health values. Errors go through ``write(_:error:)``, which
/// logs their type and a summary with no values in it (851-4183); text that could hold values
/// (a server's failure message) is `privateDetail`, which neither shows publicly nor goes to the
/// file.
///
/// Off until the app turns it on, so tests write nothing.
public enum BackfillLog {
  public static let isEnabled = LockIsolated(false)

  static let logger = Logger(subsystem: "tech.lil.health", category: "Backfill")
  private static let queue = DispatchQueue(label: "tech.lil.health.backfill-log")
  /// Past this, the file starts over, keeping the previous one as `diagnostics.1.log`.
  static let maxBytes = 512 * 1024

  static var file: URL {
    URL.applicationSupportDirectory.appending(path: "HealthBackfill/diagnostics.log")
  }

  /// Logs `message`, with the time. `privateDetail` follows it in the device's log as private
  /// (`<private>` unless the device's logging shows private data), and in the file as
  /// `<private>`: for text that could hold someone's data, such as a server's message.
  public static func write(_ message: String, privateDetail: String? = nil) {
    guard isEnabled.value else { return }
    if let privateDetail {
      logger.notice("\(message, privacy: .public): \(privateDetail, privacy: .private)")
    } else {
      logger.notice("\(message, privacy: .public)")
    }
    let line =
      "\(Date.now.formatted(.iso8601)) \(fileLine(message, privateDetail: privateDetail))\n"
    queue.async {
      let manager = FileManager.default
      let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
      if size > maxBytes {
        let previous = file.deletingLastPathComponent().appending(path: "diagnostics.1.log")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: file, to: previous)
      }
      if manager.fileExists(atPath: file.path) {
        // The throwing calls: the older ones raise an exception on an I/O error, which would
        // crash the app over a log line.
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
      } else {
        try? manager.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: file)
      }
    }
  }

  /// What the file gets for a message: never its private detail.
  static func fileLine(_ message: String, privateDetail: String?) -> String {
    privateDetail == nil ? message : "\(message): <private>"
  }

  /// Seconds since `start`, for messages.
  public static func since(_ start: ContinuousClock.Instant) -> String {
    seconds(ContinuousClock.now - start)
  }

  /// `1.25s`.
  public static func seconds(_ duration: Duration) -> String {
    (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
      .formatted(.number.precision(.fractionLength(2))) + "s"
  }

  /// A short name for a type: `HKQuantityTypeIdentifierStepCount` reads `StepCount`.
  static func name(_ type: String) -> String {
    type.components(separatedBy: "Identifier").last.flatMap { $0.isEmpty ? nil : $0 } ?? type
  }
}
