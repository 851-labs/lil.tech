#if os(macOS)
  import Darwin
  import Foundation
  import Testing

  @testable import HealthAgentAccess

  // The command line's requests for the app (851-2895). Synthetic data and temporary folders only
  // (AGENTS.md). Separate stores on one folder stand for separate processes: each opens its own
  // connection, and SQLite locks the file between connections as it does between processes.
  struct AgentActionRequestsTests {
    private let directory = URL.temporaryDirectory.appending(
      path: "AgentAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var store: AgentAccessStore { AgentAccessStore(directory: directory) }

    private func date(_ seconds: TimeInterval) -> Date {
      Date(timeIntervalSince1970: 1_760_000_000 + seconds)
    }

    private static let steps = "type:HKQuantityTypeIdentifierStepCount"

    // MARK: - Asking

    @Test
    func refusesAndAddsNothingWhileAccessIsOff() throws {
      #expect(throws: AgentAccessError.off) {
        try store.requestAction(.sync, process: "zsh", at: date(0))
      }
      try store.setEnabled(false, at: date(0))
      #expect(throws: AgentAccessError.off) {
        try store.requestAction(.sync, process: "zsh", at: date(1))
      }
      #expect(try store.claimActions(at: date(2)).isEmpty)
      #expect(try store.entries().isEmpty)
    }

    @Test
    func logsEachRequestAsTheIntentsDo() throws {
      try store.setEnabled(true, at: date(0))
      let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Downloads").path(percentEncoded: false)
      try store.requestAction(.open(page: Self.steps), process: "zsh", at: date(1))
      try store.requestAction(.open(page: "summary"), process: "zsh", at: date(2))
      try store.requestAction(.open(page: "category:heart"), process: "zsh", at: date(3))
      try store.requestAction(.sync, process: "claude", at: date(4))
      try store.requestAction(.export(folder: downloads), process: "claude", at: date(5))
      #expect(
        try store.entries().reversed().map(\.command) == [
          "open Steps", "open Summary", "open Heart", "sync", "export ~/Downloads",
        ])
      #expect(try store.entries().map(\.process).first == "claude")
    }

    @Test
    func idsAreRandom128BitHex() {
      let ids = (0..<100).map { _ in AgentActionRequest.ID.random().rawValue }
      #expect(Set(ids).count == 100)
      #expect(ids.allSatisfy { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
    }

    // MARK: - Claiming and answering

    @Test
    func theAppClaimsARequestOnceAndAnswersIt() throws {
      try store.setEnabled(true, at: date(0))
      let id = try store.requestAction(.open(page: Self.steps), process: "zsh", at: date(1))
      #expect(try store.outcome(id: id, at: date(1)) == .waiting)

      let claimed = try store.claimActions(at: date(2))
      #expect(
        claimed == [
          AgentActionRequest(id: id, action: .open(page: Self.steps), requestedAt: date(1))
        ]
      )
      #expect(try store.outcome(id: id, at: date(2)) == .running)
      // A relaunch, or a second instance, finds nothing to run.
      #expect(try AgentAccessStore(directory: directory).claimActions(at: date(3)).isEmpty)

      try store.finish(id: id, outcome: .ok(.done), at: date(4))
      #expect(try store.outcome(id: id, at: date(5)) == .finished(.ok(.done)))
      // Only the first answer counts.
      try store.finish(id: id, outcome: .failed(.signedOut), at: date(6))
      #expect(try store.outcome(id: id, at: date(7)) == .finished(.ok(.done)))
    }

    @Test
    func outcomesKeepTheirResults() throws {
      try store.setEnabled(true, at: date(0))
      let outcomes: [AgentActionOutcome] = [
        .ok(.done), .ok(.synced(at: date(0.5))), .ok(.stillSyncing),
        .ok(.exported(path: "/tmp/lil health export.tar")),
        .failed(AgentActionFailure(reason: .failed, message: "Couldn't sync: offline")),
        .failed(.signedOut),
      ]
      for outcome in outcomes {
        let id = try store.requestAction(.sync, process: "zsh", at: date(1))
        _ = try store.claimActions(at: date(1))
        try store.finish(id: id, outcome: outcome, at: date(2))
        #expect(try store.outcome(id: id, at: date(3)) == .finished(outcome))
      }
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentRequestsAndClaimsRunEachRequestOnce() async throws {
      try store.setEnabled(true)
      let directory = directory
      let count = 40
      // Two commands asking at once, while three app instances claim.
      enum Batch {
        case asked([AgentActionRequest.ID])
        case claimed([AgentActionRequest.ID])
      }
      let batches = try await withThrowingTaskGroup(of: Batch.self) { group in
        for process in ["zsh", "claude"] {
          group.addTask {
            let store = AgentAccessStore(directory: directory)
            var asked: [AgentActionRequest.ID] = []
            for _ in 0..<count / 2 {
              asked.append(try store.requestAction(.sync, process: process))
              try await Task.sleep(for: .milliseconds(2))
            }
            return .asked(asked)
          }
        }
        for _ in 0..<3 {
          group.addTask {
            let store = AgentAccessStore(directory: directory)
            var claimed: [AgentActionRequest.ID] = []
            for _ in 0..<60 {
              claimed += try store.claimActions().map(\.id)
              try await Task.sleep(for: .milliseconds(1))
            }
            return .claimed(claimed)
          }
        }
        return try await group.reduce(into: []) { $0.append($1) }
      }
      var asked: [AgentActionRequest.ID] = []
      var claimed: [AgentActionRequest.ID] = []
      for batch in batches {
        switch batch {
        case .asked(let ids): asked += ids
        case .claimed(let ids): claimed += ids
        }
      }
      // What the claimers missed by stopping early, claimed once more.
      claimed += try store.claimActions().map(\.id)
      #expect(asked.count == count)
      #expect(claimed.count == count)
      #expect(Set(claimed) == Set(asked))
      #expect(try store.entries(limit: .max).count == count)
    }

    // MARK: - What never runs

    @Test
    func requestsExpireUnclaimedAfterAMinute() throws {
      try store.setEnabled(true, at: date(0))
      let old = try store.requestAction(.sync, process: "zsh", at: date(0))
      let recent = try store.requestAction(.sync, process: "zsh", at: date(30))
      #expect(try store.outcome(id: old, at: date(61)) == nil)
      #expect(try store.claimActions(at: date(61)).map(\.id) == [recent])
      // Deleted, not just skipped.
      #expect(try store.outcome(id: old, at: date(0)) == nil)
    }

    @Test
    func aRequestDatedAheadOfTheClockExpiresToo() throws {
      try store.setEnabled(true, at: date(0))
      // Asked, then the clock was set back by an hour.
      try store.requestAction(.sync, process: "zsh", at: date(3_600))
      #expect(try store.claimActions(at: date(0)).isEmpty)
      #expect(try store.claimActions(at: date(3_600)).isEmpty)
    }

    @Test
    func accessTurnedOffBeforeTheClaimFailsTheRequest() throws {
      try store.setEnabled(true, at: date(0))
      let id = try store.requestAction(.sync, process: "zsh", at: date(1))
      try store.setEnabled(false, at: date(2))
      #expect(try store.claimActions(at: date(3)).isEmpty)
      #expect(try store.outcome(id: id, at: date(3)) == .finished(.failed(.accessOff)))
      // Turned on again, it still doesn't run.
      try store.setEnabled(true, at: date(4))
      #expect(try store.claimActions(at: date(5)).isEmpty)
    }

    @Test
    func aCommandThatStoppedWaitingCancelsItsRequest() throws {
      try store.setEnabled(true, at: date(0))
      let id = try store.requestAction(.sync, process: "zsh", at: date(1))
      #expect(try store.cancel(id: id))
      #expect(try store.outcome(id: id, at: date(1)) == nil)
      #expect(try store.claimActions(at: date(2)).isEmpty)

      // Once claimed, it runs anyway.
      let claimed = try store.requestAction(.sync, process: "zsh", at: date(3))
      _ = try store.claimActions(at: date(3))
      #expect(try store.cancel(id: claimed) == false)
      #expect(try store.outcome(id: claimed, at: date(3)) == .running)
    }

    @Test(.timeLimit(.minutes(1)))
    func aKilledCommandsRequestNeverRuns() throws {
      try store.setEnabled(true, at: date(0))
      let command = try SpawnedProcess()
      let id = try store.requestAction(
        .export(folder: "/tmp"), process: "zsh", requester: command.process, at: date(1))
      command.kill()
      #expect(try store.claimActions(at: date(2)).isEmpty)
      #expect(try store.outcome(id: id, at: date(2)) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aKilledCommandThatHasntBeenReapedCountsAsGone() throws {
      let command = try SpawnedProcess()
      let process = command.process
      command.kill(reap: false)
      // A zombie keeps its ID and start time until its parent waits for it.
      #expect(!process.isRunning)
      command.reap()
    }

    @Test
    func anotherProcessWithTheSameIDIsntTheRequester() throws {
      try store.setEnabled(true, at: date(0))
      var reused = AgentProcess.current
      reused.startedAt -= 1
      try store.requestAction(.sync, process: "zsh", requester: reused, at: date(1))
      #expect(try store.claimActions(at: date(2)).isEmpty)
    }

    // MARK: - The app quitting

    @Test(.timeLimit(.minutes(1)))
    func aRequestClaimedByAnAppThatQuitFails() throws {
      try store.setEnabled(true, at: date(0))
      let app = try SpawnedProcess()
      let id = try store.requestAction(.sync, process: "zsh", at: date(1))
      #expect(try store.claimActions(by: app.process, at: date(2)).map(\.id) == [id])
      #expect(try store.outcome(id: id, at: date(3)) == .running)

      app.kill()
      // The command hears it at once, before any app looks again.
      #expect(try store.outcome(id: id, at: date(4)) == .finished(.failed(.appQuit)))
      // A relaunched app doesn't run it again, and writes the failure.
      #expect(try store.claimActions(at: date(5)).isEmpty)
      #expect(try store.outcome(id: id, at: date(6)) == .finished(.failed(.appQuit)))
      // The app's late answer, had it written one, wouldn't count.
      try store.finish(id: id, outcome: .ok(.done), at: date(7))
      #expect(try store.outcome(id: id, at: date(8)) == .finished(.failed(.appQuit)))
    }

    @Test
    func aRunningAppsRequestDoesntExpire() throws {
      try store.setEnabled(true, at: date(0))
      let id = try store.requestAction(.export(folder: "/tmp"), process: "zsh", at: date(0))
      _ = try store.claimActions(at: date(1))
      // An export can take an hour.
      #expect(try store.claimActions(at: date(3_600)).isEmpty)
      #expect(try store.outcome(id: id, at: date(3_600)) == .running)
    }

    // MARK: - Cleaning up

    @Test
    func outcomesAreDeletedAfterTenMinutes() throws {
      try store.setEnabled(true, at: date(0))
      let id = try store.requestAction(.sync, process: "zsh", at: date(0))
      _ = try store.claimActions(at: date(1))
      try store.finish(id: id, outcome: .ok(.stillSyncing), at: date(2))
      _ = try store.claimActions(at: date(2 + 599))
      #expect(try store.outcome(id: id, at: date(2 + 599)) == .finished(.ok(.stillSyncing)))
      // Asking again sweeps, as claiming does.
      try store.requestAction(.sync, process: "zsh", at: date(2 + 601))
      #expect(try store.outcome(id: id, at: date(2 + 601)) == nil)
    }

    @Test
    func signingOutFailsWhatsUnfinishedAndDeletesTheRest() throws {
      try store.setEnabled(true, at: date(0))
      let finished = try store.requestAction(.sync, process: "zsh", at: date(1))
      let running = try store.requestAction(.export(folder: "/tmp"), process: "zsh", at: date(1))
      _ = try store.claimActions(at: date(2))
      try store.finish(id: finished, outcome: .ok(.done), at: date(3))
      let waiting = try store.requestAction(.sync, process: "zsh", at: date(4))

      try store.reset(at: date(5))
      #expect(try store.outcome(id: finished, at: date(6)) == nil)
      #expect(try store.outcome(id: running, at: date(6)) == .finished(.failed(.signedOut)))
      #expect(try store.outcome(id: waiting, at: date(6)) == .finished(.failed(.signedOut)))
      #expect(AgentActionFailure.signedOut.message == "Sign in to lil health first.")
      // The export's answer, once it stops, doesn't replace it.
      try store.finish(id: running, outcome: .ok(.exported(path: "/tmp/a.tar")), at: date(7))
      #expect(try store.outcome(id: running, at: date(8)) == .finished(.failed(.signedOut)))
      // And they go, like other outcomes.
      _ = try store.claimActions(at: date(5 + 601))
      #expect(try store.outcome(id: running, at: date(5 + 601)) == nil)
    }

    // MARK: - Another process's rows

    /// The row's format, as a command written in another language (or an older or newer
    /// `lil-health`) would write it: `/usr/bin/sqlite3`, in a process of its own.
    @Test(.timeLimit(.minutes(1)))
    func claimsARequestAnotherProcessWrote() throws {
      try store.setEnabled(true, at: date(0))
      let me = AgentProcess.current
      try sqlite3(
        """
        INSERT INTO actionRequests (id, action, requestedAt, requesterPID, requesterStartedAt)
        VALUES ('00112233445566778899aabbccddeeff', '{"action":"export","folder":"/tmp/lil"}',
          \(date(1).timeIntervalSince1970), \(me.pid), \(me.startedAt)),
        ('ffeeddccbbaa99887766554433221100', '{"action":"teleport"}',
          \(date(1).timeIntervalSince1970), \(me.pid), \(me.startedAt));
        """)
      let claimed = try store.claimActions(at: date(2))
      #expect(claimed.map(\.action) == [.export(folder: "/tmp/lil")])
      // An action this version doesn't know fails with how to fix it, rather than waiting.
      let unknown = AgentActionRequest.ID(rawValue: "ffeeddccbbaa99887766554433221100")
      guard case .finished(.failed(let failure)) = try store.outcome(id: unknown, at: date(2))
      else {
        Issue.record("Expected a failure")
        return
      }
      #expect(failure.message.contains("Update lil health"))

      try store.finish(
        id: claimed[0].id, outcome: .ok(.exported(path: "/tmp/lil/a.tar")), at: date(3))
      // And another process reads the answer.
      #expect(
        try sqlite3(
          """
          SELECT outcome, json_extract(result, '$.result'), json_extract(result, '$.path')
          FROM actionRequests WHERE id = '\(claimed[0].id)';
          """) == "ok|exported|/tmp/lil/a.tar\n")
    }

    /// A row another program finished without a result: reading it throws, rather than trapping
    /// the command that polls it.
    @Test(.timeLimit(.minutes(1)))
    func anOutcomeWithoutAResultThrows() throws {
      try store.setEnabled(true, at: date(0))
      let me = AgentProcess.current
      try sqlite3(
        """
        INSERT INTO actionRequests
          (id, action, requestedAt, requesterPID, requesterStartedAt, finishedAt, outcome)
        VALUES ('0123456789abcdef0123456789abcdef', '{"action":"sync"}',
          \(date(1).timeIntervalSince1970), \(me.pid), \(me.startedAt),
          \(date(2).timeIntervalSince1970), 'ok');
        """)
      #expect(throws: DecodingError.self) {
        try store.outcome(
          id: AgentActionRequest.ID(rawValue: "0123456789abcdef0123456789abcdef"), at: date(3))
      }
    }

    @Test
    func encodesActionsFlat() throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      func json(_ action: AgentAction) throws -> String {
        String(decoding: try encoder.encode(action), as: UTF8.self)
      }
      #expect(try json(.open(page: "summary")) == #"{"action":"open","page":"summary"}"#)
      #expect(try json(.sync) == #"{"action":"sync"}"#)
      #expect(try json(.export(folder: "/tmp")) == #"{"action":"export","folder":"\/tmp"}"#)
    }

    // MARK: - Signals

    @Test(.timeLimit(.minutes(1)))
    func signalsAtOnceThenOnEachPost() async throws {
      let name = Notification.Name("tech.lil.health.test.\(UUID().uuidString)")
      var signals = AgentActionSignal.signals(name).makeAsyncIterator()
      // At once, for what was asked before the app listened.
      #expect(await signals.next() != nil)
      // Posted until heard: delivery is asynchronous, through the system's notification server.
      let posting = Task {
        while !Task.isCancelled {
          AgentActionSignal.post(name)
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      defer { posting.cancel() }
      #expect(await signals.next() != nil)
    }

    // MARK: - Processes

    @Test
    func toldApartByWhenTheyStarted() {
      let current = AgentProcess.current
      #expect(current.pid == getpid())
      #expect(current.startedAt > 0)
      #expect(current.isRunning)
      #expect(AgentProcess(pid: -1) == nil)
    }

    @discardableResult
    private func sqlite3(_ sql: String) throws -> String {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/sqlite3")
      process.arguments = ["-cmd", ".timeout 5000", store.url.path(percentEncoded: false), sql]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      return String(decoding: data, as: UTF8.self)
    }
  }

  /// A process of its own (`sleep`), standing for a command or the app, to kill.
  private struct SpawnedProcess {
    let pid: pid_t
    let process: AgentProcess

    init() throws {
      var pid: pid_t = 0
      let arguments = ["/bin/sleep", "60"]
      var argv = arguments.map { strdup($0) } + [nil]
      defer { for argument in argv { free(argument) } }
      let status = posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, environ)
      guard status == 0, let process = AgentProcess(pid: pid) else {
        throw POSIXError(.init(rawValue: status) ?? .ESRCH)
      }
      self.pid = pid
      self.process = process
    }

    /// Kills it, then waits for it unless `reap` is false, which leaves a zombie.
    func kill(reap: Bool = true) {
      Darwin.kill(pid, SIGKILL)
      if reap {
        self.reap()
      } else {
        // Until it has died, short of being waited for.
        while AgentProcess(pid: pid)?.isRunning == true { usleep(1_000) }
      }
    }

    func reap() {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
  }
#endif
