public import Foundation
import LilCLI

/// Installs the `lil` an app bundles into a directory on `PATH`, replacing a `lil` already there
/// only if this one is newer.
///
/// It copies rather than links: `lil` finds each app's tool through Launch Services, so a copy
/// keeps working when the app moves, while a link into the app would break.
public enum CommandLineToolInstaller {
  /// Where `lil` can go.
  public enum Destination: Sendable, CaseIterable {
    /// `/usr/local/bin`, for every account. Usually needs an administrator.
    case shared
    /// `~/.local/bin`, for this account alone.
    case user

    public var directory: URL {
      switch self {
      case .shared:
        URL(filePath: "/usr/local/bin", directoryHint: .isDirectory)
      case .user:
        URL.homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory)
      }
    }
  }

  /// What's at the destination already.
  public enum Existing: Equatable, Sendable {
    case none
    case lil(version: Int)
    /// Some other command named `lil`, or one that doesn't say its version.
    case other
  }

  /// What installing does about what's there.
  public enum Decision: Equatable, Sendable {
    case install
    case replace(version: Int)
    /// The `lil` there is this version, or newer.
    case keep(version: Int)
    /// Another command named `lil`, which isn't ours to replace.
    case leaveAlone
  }

  public static func decide(bundledVersion: Int, existing: Existing) -> Decision {
    switch existing {
    case .none:
      .install
    case .lil(let version) where version < bundledVersion:
      .replace(version: version)
    case .lil(let version):
      .keep(version: version)
    case .other:
      .leaveAlone
    }
  }

  public enum Outcome: Equatable, Sendable {
    case installed(URL, replacedVersion: Int?)
    /// A `lil` of this version, or a newer one, was there already.
    case upToDate(URL, version: Int)
    /// Another command named `lil` was there, and was left alone.
    case otherCommand(URL)
    /// The administrator prompt was cancelled.
    case cancelled
  }

  public struct Failure: Error, LocalizedError, Equatable {
    public var errorDescription: String?
  }

  /// What's at `url`. A broken link counts as nothing, so installing replaces it.
  public static func existing(at url: URL) -> Existing {
    guard FileManager.default.fileExists(atPath: url.path) else { return .none }
    return LilCLI.version(of: url).map(Existing.lil(version:)) ?? .other
  }

  /// Installs `bundled` as `lil` in `directory`, asking for an administrator's password if this
  /// account can't write there.
  ///
  /// On a dispatch queue: it waits on processes, the administrator prompt among them, which would
  /// hold one of Swift concurrency's few threads for as long as the prompt stays open.
  public static func install(_ bundled: URL, into directory: URL) async throws -> Outcome {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try installNow(bundled, into: directory) })
      }
    }
  }

  private static func installNow(_ bundled: URL, into directory: URL) throws -> Outcome {
    guard let bundledVersion = LilCLI.version(of: bundled) else {
      throw Failure(errorDescription: "The command line tool at \(bundled.path) doesn't run.")
    }
    let destination = directory.appending(component: "lil")
    let replacedVersion: Int?
    switch decide(bundledVersion: bundledVersion, existing: existing(at: destination)) {
    case .install:
      replacedVersion = nil
    case .replace(let version):
      replacedVersion = version
    case .keep(let version):
      return .upToDate(destination, version: version)
    case .leaveAlone:
      return .otherCommand(destination)
    }
    let arguments = [copyScript, "sh", directory.path, bundled.path]
    if isWritable(directory) {
      try run(URL(filePath: "/bin/sh"), arguments: ["-c"] + arguments)
    } else {
      // The same script, as root. The paths are arguments, not part of the script.
      let appleScript = [
        "on run argv",
        """
        do shell script "/bin/sh -c " & quoted form of item 1 of argv & " " & \
        quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & \
        quoted form of item 4 of argv with administrator privileges
        """,
        "end run",
      ]
      do {
        try run(
          URL(filePath: "/usr/bin/osascript"),
          arguments: appleScript.flatMap { ["-e", $0] } + arguments
        )
      } catch let failure as Failure where failure.errorDescription?.contains("(-128)") == true {
        // "User canceled. (-128)"
        return .cancelled
      }
    }
    return .installed(destination, replacedVersion: replacedVersion)
  }

  /// Copies `$2` to `$1/lil`, creating `$1` if needed. Through a temporary file of its own, so the
  /// old `lil` is replaced at once, and without extended attributes, so the copy isn't quarantined
  /// (the signature is in the binary).
  static let copyScript = """
    set -e
    mkdir -p "$1"
    new="$1/.lil.new.$$"
    cp -X "$2" "$new"
    chmod 755 "$new"
    mv -f "$new" "$1/lil"
    """

  /// Whether this account can write `directory`, or create it: true if its closest existing
  /// ancestor is writable.
  static func isWritable(_ directory: URL) -> Bool {
    var url = directory.standardizedFileURL
    while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
      url.deleteLastPathComponent()
    }
    return FileManager.default.isWritableFile(atPath: url.path)
  }

  private static func run(_ executable: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(
        errorDescription: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Copying the command line tool failed."
          : message.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
