public import Foundation

// What didn't go up, and the batches whose outcome isn't known yet (851-4151). A record that
// can't be encoded, is too long for the server, or that the server refuses, used to be reported
// and dropped while the anchor moved past it, so nobody saw it and it never went up.

extension HealthBackfillState {
  /// A type's records that didn't go up, which Sync Status counts and the backfill tries again.
  public struct HeldBack: Codable, Equatable, Sendable {
    /// Up to `HealthBackfill.maxHeldRecords`, by ID (the object's lowercase UUID, as in its
    /// mutation).
    public var records: [String: HeldRecord] = [:]
    /// Those past the limit, and those the server refused without naming them: counted, but not
    /// known by ID, so after an update the type is read again from the start instead.
    public var unnamed = 0
    /// The build that counted `unnamed`.
    public var unnamedBuild: String?

    public init() {}

    public var count: Int { records.count + unnamed }
  }

  public struct HeldRecord: Codable, Equatable, Sendable {
    public var reason: HoldReason
    /// The app's build when it was held back.
    public var build: String

    public init(reason: HoldReason, build: String) {
      self.reason = reason
      self.build = build
    }

    /// Whether a run of everything tries it again: one that couldn't be read, or whose batch
    /// failed, every time; one too long or refused only once the app has been updated, since
    /// the same build would send the same line.
    func isDue(build current: String) -> Bool {
      switch reason {
      case .unreadable, .failed: true
      case .tooLarge, .refused: build != current
      }
    }
  }

  public enum HoldReason: String, Codable, Sendable {
    /// It couldn't be read or encoded.
    case unreadable
    /// Its line was over the server's 1 MB, or its blob over 16 MB.
    case tooLarge
    /// The server refused its line.
    case refused
    /// The server failed the batch it was sent again in.
    case failed
  }

  /// A type's page the server accepted, whose batches' outcome hasn't been checked yet
  /// (`HealthBatchStatusReader`): the queue applies them afterwards. Only pages of records read
  /// from anchors are checked; sums and what's read whole each run go up again when they change.
  public struct UploadedPage: Codable, Equatable, Sendable {
    public var type: String
    /// Those not checked yet.
    public var batches: [String]
    /// The anchor the page was read from (`nil` for the type's first), which the type goes back
    /// to if one of its batches fails, so the page is read and sent again.
    public var from: Data?
    public var records: Int
    /// For held-back records sent again: their IDs, held back again if a batch fails.
    public var retried: [String]?
  }
}
