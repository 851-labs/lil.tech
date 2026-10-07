import MessageSending
import Testing

struct MessageSenderTests {
  @Test
  func passesArgumentsVerbatim() async throws {
    try await runAppleScript(
      """
      on run argv
        if item 1 of argv is not "He said \\"hi\\" \\\\ $HOME" then error "Wrong text" number 1
        if item 2 of argv is not "iMessage;-;+15550000001" then error "Wrong chat" number 2
      end run
      """,
      arguments: [#"He said "hi" \ $HOME"#, "iMessage;-;+15550000001"]
    )
  }

  @Test(
    arguments: [
      (-1743, MessageSendError.automationDenied),
      (-1728, .chatNotFound),
      (-600, .messagesUnavailable),
    ]
  )
  func mapsKnownErrors(code: Int, expected: MessageSendError) async {
    await #expect(throws: expected) {
      try await runAppleScript(
        "on run argv\n  error \"Failure\" number \(code)\nend run",
        arguments: []
      )
    }
  }

  @Test
  func reportsOtherScriptErrors() async throws {
    let error = try await #require(throws: MessageSendError.self) {
      try await runAppleScript("on run argv\n  error \"Boom\" number 42\nend run", arguments: [])
    }
    guard case .scriptFailed(let code, let message) = error else {
      Issue.record("Expected scriptFailed, got \(error)")
      return
    }
    #expect(code == 42)
    #expect(message.contains("Boom"))
  }
}
