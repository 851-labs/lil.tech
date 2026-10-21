import Foundation
import Testing

@testable import HealthAgentAccess

// Synthetic data only (AGENTS.md).
struct AgentAccessStoreTests {
  private let directory = URL.temporaryDirectory.appending(
    path: "AgentAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var store: AgentAccessStore { AgentAccessStore(directory: directory) }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_760_000_000 + seconds)
  }

  @Test
  func accessIsOffUntilTurnedOnWithoutCreatingTheFile() throws {
    #expect(try store.isEnabled() == false)
    #expect(try store.entries().isEmpty)
    #expect(throws: AgentAccessError.off) {
      try store.authorize(command: "summary", process: "zsh")
    }
    #expect(!FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
  }

  @Test
  func savesThatFinishOutOfOrderEndAsThePersonLeftTheSetting() throws {
    // Turned on, then off, but the second save is written first.
    try store.setEnabled(false, at: date(2))
    try store.setEnabled(true, at: date(1))
    #expect(try store.isEnabled() == false)

    // Nor does a save from before signing out undo it.
    try store.setEnabled(true, at: date(3))
    try store.reset(at: date(5))
    try store.setEnabled(true, at: date(4))
    #expect(try store.isEnabled() == false)
  }

  @Test
  func refusesWhileOffAndLogsEachQueryWhileOn() throws {
    #expect(throws: AgentAccessError.off) {
      try store.authorize(command: "summary", process: "zsh", at: date(0))
    }

    try store.setEnabled(true, at: date(1))
    #expect(try store.isEnabled())
    try store.authorize(command: "summary", process: "zsh", at: date(2))
    try store.authorize(command: "metric Steps --range W", process: "claude", at: date(3))
    #expect(
      try store.entries() == [
        AgentAccessEntry(
          id: 2, date: date(3), command: "metric Steps --range W", process: "claude"),
        AgentAccessEntry(id: 1, date: date(2), command: "summary", process: "zsh"),
      ])

    // Turned off again, it refuses, and the log stays.
    try store.setEnabled(false, at: date(4))
    #expect(throws: AgentAccessError.off) {
      try store.authorize(command: "summary", process: "zsh", at: date(5))
    }
    #expect(try store.entries().count == 2)
  }

  @Test
  func theLogKeepsTheLatestEntries() throws {
    for index in 0..<(AgentAccessStore.logLimit + 5) {
      try store.record(command: "types", process: "zsh", at: date(TimeInterval(index)))
    }
    let entries = try store.entries(limit: .max)
    #expect(entries.count == AgentAccessStore.logLimit)
    #expect(entries.first?.date == date(TimeInterval(AgentAccessStore.logLimit + 4)))
    #expect(entries.last?.date == date(5))
  }

  @Test
  func resetTurnsAccessOffAndEmptiesTheLog() throws {
    try store.setEnabled(true, at: date(0))
    try store.record(command: "sleep", process: "claude")
    try store.reset(at: date(1))
    #expect(try store.isEnabled() == false)
    #expect(try store.entries().isEmpty)
  }

  @Test
  func anotherConnectionSeesTheSettingAtOnce() throws {
    // As the CLI or an MCP server would, with its own store on the same folder.
    let other = AgentAccessStore(directory: directory)
    try store.setEnabled(true, at: date(0))
    #expect(try other.isEnabled())
    try store.setEnabled(false, at: date(1))
    #expect(throws: AgentAccessError.off) {
      try other.authorize(command: "workouts", process: "claude")
    }
  }

  @Test
  func theErrorSaysHowToTurnAccessOn() {
    #expect(AgentAccessError.off.localizedDescription.contains("Settings"))
  }

  #if os(macOS)
    @Test
    func namesTheCallingProcess() {
      #expect(AgentAccessStore.callingProcess(of: getpid())?.isEmpty == false)
      #expect(AgentAccessStore.callingProcess(of: -1) == nil)
    }
  #endif
}
