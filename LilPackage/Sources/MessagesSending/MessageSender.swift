public import Dependencies
import Foundation

/// Sends messages by scripting Messages.app.
///
/// The script is fixed and receives the text and chat ID as arguments, so message content is never
/// spliced into AppleScript source. It runs in `/usr/bin/osascript` rather than in-process with
/// `NSAppleScript`, so a slow or unresponsive Messages.app never blocks the main thread.
public struct MessageSender: Sendable {
  public var send: @Sendable (_ text: String, _ chatGUID: String) async throws -> Void

  public init(send: @escaping @Sendable (_ text: String, _ chatGUID: String) async throws -> Void) {
    self.send = send
  }
}

public enum MessageSendError: Error, Equatable, Sendable {
  /// The user hasn't allowed lil messages to control Messages.app (System Settings › Privacy &
  /// Security › Automation).
  case automationDenied
  /// Messages.app doesn't know the chat, e.g. it was deleted.
  case chatNotFound
  /// Messages.app isn't installed or couldn't be launched.
  case messagesUnavailable
  case scriptFailed(code: Int?, message: String)
}

extension MessageSender {
  public static var live: Self {
    Self { text, chatGUID in
      try await runAppleScript(sendTextScript, arguments: [text, chatGUID])
    }
  }

  static let sendTextScript = """
    on run argv
      set theText to item 1 of argv
      set theChatID to item 2 of argv
      with timeout of 30 seconds
        tell application "Messages"
          send theText to chat id theChatID
        end tell
      end timeout
    end run
    """
}

extension MessageSender: DependencyKey {
  public static var liveValue: Self {
    .live
  }

  public static var testValue: Self {
    Self(send: unimplemented("MessageSender.send"))
  }

  public static var previewValue: Self {
    Self { _, _ in }
  }
}

extension DependencyValues {
  public var messageSender: MessageSender {
    get { self[MessageSender.self] }
    set { self[MessageSender.self] = newValue }
  }
}

/// Runs AppleScript `source` with `osascript`, passing `arguments` to its `run` handler.
public func runAppleScript(_ source: String, arguments: [String]) async throws {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/osascript")
  process.arguments = ["-"] + arguments
  let input = Pipe()
  let standardError = Pipe()
  process.standardInput = input
  process.standardOutput = FileHandle.nullDevice
  process.standardError = standardError

  let status: Int32 = try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { process in
      continuation.resume(returning: process.terminationStatus)
    }
    do {
      try process.run()
      input.fileHandleForWriting.write(Data(source.utf8))
      try input.fileHandleForWriting.close()
    } catch {
      process.terminationHandler = nil
      continuation.resume(throwing: error)
    }
  }

  guard status != 0 else { return }
  let message = String(
    decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
    as: UTF8.self
  )
  throw MessageSendError(osascriptError: message)
}

extension MessageSendError {
  /// Maps `osascript`'s error output, e.g. `12:40: execution error: Message (-1743)`.
  init(osascriptError output: String) {
    let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = message.firstMatch(of: /\((-?\d+)\)$/).flatMap { Int($0.1) }
    switch code {
    case -1743:
      self = .automationDenied
    case -1728:
      self = .chatNotFound
    case -600, -10814:
      self = .messagesUnavailable
    default:
      self = .scriptFailed(code: code, message: message)
    }
  }
}
