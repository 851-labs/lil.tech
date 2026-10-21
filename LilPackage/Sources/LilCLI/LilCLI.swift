public import Foundation

/// The `lil` command: `lil <app> <arguments…>` runs the app's own command line tool,
/// `lil-<app> <arguments…>`, like git runs `git-<command>`. Every lil app bundles `lil`, and
/// `lil-<app>` if it has a tool, so no two apps install the same command.
public enum LilCLI {
  /// Runs `lil` with the process's arguments and environment.
  public static func main() -> Never {
    let dispatcher = Dispatcher.live()
    perform(dispatcher.action(for: Array(CommandLine.arguments.dropFirst())), with: dispatcher)
  }

  static func perform(_ action: Action, with dispatcher: Dispatcher) -> Never {
    switch action {
    case .serveMCP:
      LilMCPServer.serve(dispatcher: dispatcher)
    case .print(let text, let status):
      FileHandle.standardOutput.write(Data(text.utf8))
      exit(status)
    case .printError(let text, let status):
      FileHandle.standardError.write(Data(text.utf8))
      exit(status)
    case .exec(let tool, let arguments):
      // The tool's own path as its argv[0], as a shell would pass it.
      let argv = ([tool.path] + arguments).map { strdup($0) } + [nil]
      execv(tool.path, argv)
      // Only reached if the tool couldn't be run.
      let reason = String(cString: strerror(errno))
      FileHandle.standardError.write(Data("lil: couldn't run \(tool.path): \(reason)\n".utf8))
      exit(Action.cannotExecuteStatus)
    }
  }

  /// This copy's version, which `lil --version` prints as `lil <version>`: the build number
  /// (`CFBundleVersion`, in the info section the apps' `lil` target embeds) of the app it shipped
  /// in. Releases number builds by the repo's commit count, so a newer `lil` has a higher one,
  /// whichever app it came with. 0 for builds without one (`swift run lil`).
  public static let version: Int = {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
      ?? 0
  }()

  /// The version a `lil --version`'s output names, or nil if it isn't a `lil`'s.
  public static func version(fromOutput output: String) -> Int? {
    let words = output.split(whereSeparator: \.isNewline).first?.split(separator: " ") ?? []
    guard words.count == 2, words[0] == "lil" else { return nil }
    return Int(words[1])
  }

  /// The version of the `lil` at `url`, from its `--version`, or nil if it isn't a `lil`.
  public static func version(of url: URL) -> Int? {
    output(of: url, arguments: ["--version"]).flatMap(version(fromOutput:))
  }

  /// A tool's one-line description, the first line of its `--describe`.
  public static func description(of tool: URL) -> String? {
    output(of: tool, arguments: ["--describe"])?
      .split(whereSeparator: \.isNewline).first
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// What `executable` prints to standard output, with nothing on its standard input. Nil if it
  /// can't be run, fails, or takes longer than `timeout`, so a tool that hangs can't hang `lil`.
  public static func output(
    of executable: URL,
    arguments: [String],
    timeout: Duration = .seconds(5)
  ) -> String? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    // Read while it runs, so output that fills the pipe can't block it.
    let output = Output()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      output.data = pipe.fileHandleForReading.readDataToEndOfFile()
      read.signal()
    }
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    guard exited.wait(timeout: .now() + seconds) == .success else {
      process.terminate()
      return nil
    }
    // Something the tool started could keep the pipe open after it exits.
    guard read.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else {
      return nil
    }
    return String(decoding: output.data, as: UTF8.self)
  }
}

/// The reader's result, which `read` hands over to the caller.
private final class Output: @unchecked Sendable {
  var data = Data()
}
