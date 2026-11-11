import ComposableArchitecture
import LilTestSupport
import Testing

@testable import HealthMacApp

/// Signs the store in through its session's updates, and waits until it serves app actions
/// (851-4208). It starts reading `channel.requests()` in an effect of its own, which may not have
/// run yet when `signedInChanged` is received, and an action asked before then fails at once,
/// signed out, with a zero `signInWait`.
@MainActor
func signIn(
  _ store: TestStoreOf<AppFeature>, session: AsyncStream<Bool>.Continuation,
  servingFrom channel: HealthAppActionChannel,
  fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line,
  column: UInt = #column
) async throws {
  session.yield(true)
  await store.receive(
    \.signedInChanged, fileID: fileID, file: filePath, line: line, column: column)
  try await eventually(
    { channel.hasServer },
    sourceLocation: SourceLocation(
      fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column)))
}
