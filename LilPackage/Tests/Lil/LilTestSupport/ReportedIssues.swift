import Dependencies
import IssueReporting

/// Runs `operation`, collecting what the code under test reports with `reportIssue` instead of
/// recording each as a test failure, and returns the messages in order, so a test asserts them
/// exactly: `#expect(issues == ["Skipped note change 1: …"])`. A reported error's message is
/// IssueReporting's, `"Caught error: \(error)"`.
///
/// Use it instead of `withKnownIssue` for issues a test expects (851-4051). Swift Testing prints
/// every known issue, with its message, in a passing run's output, and a known issue matches any
/// issue, even a failed `#expect` in the block. Here, a test whose code reports nothing, or
/// something else as well, fails on the comparison, which shows what was reported. What isn't
/// reported through `reportIssue` (a failed `#expect`, `Issue.record`, a thrown error) still fails
/// the test as usual, as does an issue reported from a task that doesn't inherit the operation's
/// task-local values (`Task.detached`, a `DispatchQueue`). Asynchronous only, since swift-format
/// refuses a synchronous overload a trailing closure can't tell apart: call it from an `async`
/// test, with a synchronous closure if you like.
public func issuesReported(by operation: () async throws -> Void) async rethrows -> [String] {
  let reporter = CollectingIssueReporter()
  try await withIssueReporters([reporter], operation: operation)
  return reporter.messages.value
}

private final class CollectingIssueReporter: IssueReporter {
  let messages = LockIsolated<[String]>([])

  func reportIssue(
    _ message: @autoclosure () -> String?,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    let message = message() ?? ""
    messages.withValue { $0.append(message) }
  }
}
