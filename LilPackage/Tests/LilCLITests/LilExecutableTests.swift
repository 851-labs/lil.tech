import Foundation
import Testing

/// Runs the built `lil` (the package's `lil` product) against a fake `lil-test` on `PATH`, to check
/// that what reaches the tool, and what comes back, is untouched.
struct LilExecutableTests {
  /// `swift test` builds every product next to the test bundle.
  let lil = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "lil")
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
