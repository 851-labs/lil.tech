import Foundation
import Testing

/// Runs the built `lil` (the package's `lil-dev` product) against a fake `lil-test` on `PATH`, to check
/// that what reaches the tool, and what comes back, is untouched.
struct LilExecutableTests {
  /// `swift test` builds every product next to the test bundle.
  let lil = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(
    path: "lil-dev")
  let directory: URL

  init() throws {
    directory = try makeTemporaryDirectory()
    // Prints each argument on a line of its own, then standard input, and exits with 3.
    try writeScript(
      """
      echo "argv0=$0"
      for argument in "$@"; do echo "[$argument]"; done
      echo "stdin=$(cat)"
      echo "to stderr" >&2
      exit 3
      """,
      to: directory.appending(path: "lil-test")
    )
  }

  @Test
  func execsTheToolWithItsArgumentsInputOutputAndStatus() throws {
    try #require(
      FileManager.default.isExecutableFile(atPath: lil.path),
      "no lil at \(lil.path)"
    )
    let result = try run(["test", "summary", "two words", "", "--help", "-x"], input: "piped")

    #expect(
      result.output == """
        argv0=\(directory.appending(path: "lil-test").path)
        [summary]
        [two words]
        []
        [--help]
        [-x]
        stdin=piped

        """
    )
    #expect(result.error == "to stderr\n")
    #expect(result.status == 3)
  }

  @Test
  func failsForAnAppWithoutATool() throws {
    try #require(FileManager.default.isExecutableFile(atPath: lil.path))
    let result = try run(["nope", "x"], input: "")

    #expect(result.output.isEmpty)
    #expect(result.error.contains("'nope' isn't an installed lil app"))
    #expect(result.status == 127)
  }

  /// `lil mcp` as an agent runs it: JSON-RPC messages, one per line, on standard input and
  /// output, until it closes them. Its home is a temporary folder, so an installed lil health's
  /// server, which it may start, reads nothing real.
  @Test
  func servesMCPOverStandardInputAndOutput() throws {
    try #require(FileManager.default.isExecutableFile(atPath: lil.path))
    let process = Process()
    process.executableURL = lil
    process.arguments = ["mcp"]
    process.environment = [
      "PATH": "\(directory.path):/usr/bin:/bin",
      "CFFIXED_USER_HOME": directory.appending(path: "home").path,
    ]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    // A server that stops answering fails the test rather than hanging it.
    let watchdog = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
    defer { watchdog.cancel() }

    let initialize: [String: Any] = [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": [
        "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
        "clientInfo": ["name": "LilExecutableTests", "version": "1"],
      ],
    ]
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: initialize) + [10])
    var line = Data()
    while !line.contains(10) {
      let data = output.fileHandleForReading.availableData
      guard !data.isEmpty else { break }
      line += data
    }
    let response =
      try JSONSerialization.jsonObject(with: line.prefix { $0 != 10 }) as? [String: Any]
    let result = response?["result"] as? [String: Any]
    #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "lil")
    #expect((result?["instructions"] as? String)?.hasPrefix("Tools from the lil apps") == true)

    // Closing its input ends it.
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit && process.terminationStatus == 0)
  }

  private func run(
    _ arguments: [String],
    input: String
  ) throws -> (output: String, error: String, status: Int32) {
    let process = Process()
    process.executableURL = lil
    process.arguments = arguments
    process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      String(decoding: output, as: UTF8.self),
      String(decoding: error, as: UTF8.self),
      process.terminationStatus
    )
  }
}

private final class Marker {}
