import Dependencies
import IssueReporting

/// Runs `operation`, collecting what the code under test reports with `reportIssue` instead of
/// recording each as a test failure, and returns the messages in order, so a test asserts them
/// exactly: `#expect(issues == ["Skipped note change 1: …"])`. A reported error's message is
/// IssueReporting's: `"Caught error: \(error)"`, followed by `": \(message)"` when it has one.
///
/// Use it instead of `withKnownIssue` for issues a test expects (851-4051). Swift Testing prints
/// every known issue, with its message, in a passing run's output, and a known issue matches any
/// issue, even a failed `#expect` in the block. Here nothing is hidden:
/// - Everything reported through `reportIssue` while `operation` runs is in the list, including
///   what TCA's `TestStore` and unimplemented dependencies report, so a test whose code reports
///   nothing, or something more, fails on the comparison, which shows what was reported.
/// - What isn't reported through `reportIssue` (a failed `#expect`, `Issue.record`) fails the test
///   as usual, as does what's reported from a task that doesn't inherit the operation's task-local
///   values (`Task.detached`, a `DispatchQueue`).
/// - What a task started inside reports after `operation` returns, and what was collected when
///   `operation` throws, goes to the test's own reporters, at its own source location, and fails it.
///
/// Asynchronous only, since swift-format refuses a synchronous overload a trailing closure can't
/// tell apart: call it from an `async` test, with a synchronous closure if you like.
public func issuesReported(by operation: () async throws -> Void) async rethrows -> [String] {
  let reporter = CollectingIssueReporter(passingOnTo: IssueReporters.current)
  do {
    try await withIssueReporters([reporter], operation: operation)
  } catch {
    reporter.stopCollecting(passingOnCollected: true)
    throw error
  }
  return reporter.stopCollecting(passingOnCollected: false)
}

/// Collects issues until it's stopped, then passes what's reported on to `later`, the reporters
/// that were current before.
private final class CollectingIssueReporter: IssueReporter {
  private struct Report {
    var message: String
    var severity: IssueSeverity
    var fileID: StaticString
    var filePath: StaticString
    var line: UInt
    var column: UInt
  }

  private let later: [any IssueReporter]
  /// `nil` once stopped.
  private let collected = LockIsolated<[Report]?>([])

  init(passingOnTo reporters: [any IssueReporter]) {
    later = reporters
  }

  /// Stops collecting, and returns the messages collected, after passing their issues on to
  /// `later` if `passingOnCollected`.
  @discardableResult
  func stopCollecting(passingOnCollected: Bool) -> [String] {
    let issues = collected.withValue { collected in
      defer { collected = nil }
      return collected ?? []
    }
    if passingOnCollected {
      for issue in issues { passOn(issue) }
    }
    return issues.map(\.message)
  }

  func reportIssue(
    _ message: @autoclosure () -> String?,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    let issue = Report(
      message: message() ?? "", severity: severity, fileID: fileID, filePath: filePath,
      line: line, column: column)
    let isCollecting = collected.withValue { collected in
      collected?.append(issue)
      return collected != nil
    }
    if !isCollecting { passOn(issue) }
  }

  private func passOn(_ issue: Report) {
    for reporter in later {
      reporter.reportIssue(
        issue.message, severity: issue.severity, fileID: issue.fileID, filePath: issue.filePath,
        line: issue.line, column: issue.column)
    }
  }
}
