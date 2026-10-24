import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthAgentAccess
import HealthDatabase
import LilAuth
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthMacApp

private let archive = URL(string: "https://api.lil.tech/v1/exports/download?token=t")!
private let requestedAt = Date(timeIntervalSince1970: 1_792_540_800)
private let name = "lil-export-2026-10-21.tar"

// Export lil health Data (851-2894). Synthetic data only: the archives are a line of text, in
// temporary folders.
// Signing in follows the account's cards (851-3204), in a database of their own.
@Suite(.dependencies { $0.defaultDatabase = try! HealthDatabase.make() })
@MainActor
struct ExportHealthDataIntentTests {
  private let directory = URL.temporaryDirectory.appending(
    path: "ExportHealthData-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var accessStore: AgentAccessStore {
    AgentAccessStore(directory: directory.appending(path: "AgentAccess"))
  }

  /// A folder to export into, made for the test.
  private func makeFolder(_ name: String = "Exports") throws -> URL {
    let folder = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A store whose export is ready at once, downloading a synthetic archive each time it's asked.
  private func makeStore(
    _ status: DataExportFeature.State.Status = .idle,
    requests: LockIsolated<Int> = LockIsolated(0)
  ) -> TestStoreOf<AppFeature> {
    var state = AppFeature.State(isSignedIn: true)
    state.account.dataExport.status = status
    return TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [directory] in
      $0.continuousClock = RecordingClock()
      // The server's rule: asked again the same day, it answers with the same export.
      $0.dataExports.request = { () throws(DataExportError) in
        requests.withValue { $0 += 1 }
        return DataExport(requestedAt: requestedAt, url: archive)
      }
      $0.dataExports.download = { url in
        #expect(url == archive)
        let file = directory.appending(path: UUID().uuidString)
        try? Data("synthetic archive".utf8).write(to: file)
        return AsyncThrowingStream {
          $0.yield(.progress(0.5))
          $0.yield(.finished(file: file, name: name))
          $0.finish()
        }
      }
      $0.archiveSaver.checkFolder = { try ArchiveSaver.checkFolder($0) }
      $0.archiveSaver.saveToFolder = { try ArchiveSaver.move($0, named: $1, into: $2) }
    }
  }

  // MARK: - AppFeature

  @Test(.timeLimit(.minutes(1)))
  func exportsToTheFolderWithoutThePanel() async throws {
    let folder = try makeFolder()
    let store = makeStore()
    let (request, answer, progress) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(request))
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    await store.receive(\.account.dataExport.prepared) {
      $0.account.dataExport.status = .downloading(0)
    }
    await store.receive(\.account.dataExport.downloadProgressed) {
      $0.account.dataExport.status = .downloading(0.5)
    }
    let saved = folder.appending(path: name)
    // Settings shows it saved, with Show in Finder.
    await store.receive(\.account.dataExport.saved) {
      $0.account.dataExport.status = .saved(saved)
    }
    #expect(try await answer() == .exported(saved))
    #expect(progress.value == [.preparing, .downloading(0), .downloading(0.5)])
    #expect(try String(contentsOf: saved, encoding: .utf8) == "synthetic archive")
  }

  @Test(.timeLimit(.minutes(1)))
  func askingAgainTheSameDaySavesThatExportUnderANumberedName() async throws {
    let folder = try makeFolder()
    let requests = LockIsolated(0)
    let store = makeStore(requests: requests)
    store.exhaustivity = .off

    let (first, firstAnswer, _) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(first))
    #expect(try await firstAnswer() == .exported(folder.appending(path: name)))
    await store.skipReceivedActions()

    // The server answers with the export it prepared earlier today; the name is taken.
    let (second, secondAnswer, _) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(second))
    let numbered = folder.appending(path: "lil-export-2026-10-21 2.tar")
    #expect(try await secondAnswer() == .exported(numbered))
    await store.skipReceivedActions()
    #expect(store.state.account.dataExport.status == .saved(numbered))
    #expect(requests.value == 2)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        == ["lil-export-2026-10-21 2.tar", name])
  }

  @Test(.timeLimit(.minutes(1)))
  func refusesWhileAnExportIsRunning() async throws {
    let folder = try makeFolder()
    let requests = LockIsolated(0)
    // One started in Settings, downloading.
    let store = makeStore(.downloading(0.3), requests: requests)
    let (request, answer, _) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(request))
    await store.receive(\.account.dataExport.exportToFolderRequested)
    await #expect(throws: HealthAppActionError.exportRunning) { try await answer() }
    #expect(
      HealthAppActionError.exportRunning.localizedDescription == "An export is already running.")
    #expect(requests.value == 0)
  }

  @Test
  func theButtonDoesNothingWhileAnExportIsRunning() async {
    // An action's export, downloading: the button can't cancel it to start another.
    let store = makeStore(.downloading(0.3))
    await store.send(.account(.dataExport(.exportButtonTapped)))
  }

  @Test
  func onlyTheLastPartOfTheServersNameIsUsed() throws {
    let folder = try makeFolder()
    let file = directory.appending(path: UUID().uuidString)
    try Data("synthetic archive".utf8).write(to: file)
    let saved = try ArchiveSaver.move(file, named: "../../\(name)", into: folder)
    #expect(saved == folder.appending(path: name))
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailureSaysWhyInSettingsAndToTheAction() async throws {
    let folder = try makeFolder()
    let store = makeStore()
    store.dependencies.dataExports.request = { () throws(DataExportError) in throw .unavailable }
    let (request, answer, _) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(request))
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    await store.receive(\.account.dataExport.failed) {
      $0.account.dataExport.status = .failed(DataExportError.unavailable.message)
    }
    let error = await #expect(throws: HealthAppActionError.self) { try await answer() }
    #expect(error == .exportFailed(DataExportError.unavailable.message))
    #expect(error?.localizedDescription == DataExportError.unavailable.message)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFolderThatCantBeWrittenToFailsBeforeAskingTheServer() async throws {
    let readOnly = try makeFolder("Read Only")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    }
    let requests = LockIsolated(0)
    let store = makeStore(requests: requests)
    let path = HealthAppAction.displayPath(readOnly)

    let (request, answer, _) = makeRequest(.export(to: readOnly))
    await store.send(.appActionRequested(request))
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    await store.receive(\.account.dataExport.failed) {
      $0.account.dataExport.status = .failed(
        HealthAppActionError.folderNotWritable(path).localizedDescription)
    }
    await #expect(throws: HealthAppActionError.folderNotWritable(path)) { try await answer() }

    // Nor one that isn't there.
    let missing = directory.appending(path: "Missing", directoryHint: .isDirectory)
    let (missingRequest, missingAnswer, _) = makeRequest(.export(to: missing))
    await store.send(.appActionRequested(missingRequest))
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    await store.receive(\.account.dataExport.failed) {
      $0.account.dataExport.status = .failed(
        "There's no folder at \(HealthAppAction.displayPath(missing)).")
    }
    await #expect(throws: HealthAppActionError.folderNotFound(HealthAppAction.displayPath(missing)))
    {
      try await missingAnswer()
    }
    #expect(requests.value == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingInSettingsFailsTheAction() async throws {
    let folder = try makeFolder()
    let store = makeStore()
    // Waits for the export until cancelled.
    store.dependencies.continuousClock = RecordingClock(immediateSleeps: 0)
    store.dependencies.dataExports.request = { () throws(DataExportError) in
      DataExport(requestedAt: requestedAt, url: nil)
    }
    let (request, answer, _) = makeRequest(.export(to: folder))
    await store.send(.appActionRequested(request))
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    await store.send(.account(.dataExport(.cancelButtonTapped))) {
      $0.account.dataExport.status = .idle
    }
    await #expect(throws: HealthAppActionError.exportCancelled) { try await answer() }
  }

  @Test(.timeLimit(.minutes(1)))
  func signingOutWhileExportingFailsTheExport() async throws {
    let folder = try makeFolder()
    let actions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.healthAppActions = actions
      $0.sync = .constant(.idle)
      $0.continuousClock = RecordingClock(immediateSleeps: 0)
      $0.dataExports.request = { () throws(DataExportError) in
        DataExport(requestedAt: requestedAt, url: nil)
      }
      $0.archiveSaver.checkFolder = { try ArchiveSaver.checkFolder($0) }
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged)

    let exporting = Task { try await actions.perform(.export(to: folder), { _ in }) }
    await store.receive(\.account.dataExport.exportToFolderRequested) {
      $0.account.dataExport.status = .preparing
    }
    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.account.dataExport.status = .idle
    }
    await #expect(throws: HealthAppActionError.signedOut) { try await exporting.value }
    await task.cancel()
    await store.finish()
  }

  // MARK: - The intent

  @Test
  func refusesAndLogsNothingWhileAccessIsOff() async throws {
    let folder = try makeFolder()
    let asked = LockIsolated<[HealthAppAction]>([])
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, _ in
        asked.withValue { $0.append(action) }
        return .exported(folder.appending(path: name))
      }
    } operation: {
      let error = await #expect(throws: HealthAppIntentError.self) {
        try await ExportHealthDataIntent.export(to: folder) { _ in }
      }
      #expect(error?.message == AgentAccessError.off.localizedDescription)
    }
    #expect(asked.value.isEmpty)
    #expect(try accessStore.entries().isEmpty)
  }

  @Test
  func logsTheFolderThenAsksTheAppWhileAccessIsOn() async throws {
    try accessStore.setEnabled(true)
    let downloads = URL.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    let saved = downloads.appending(path: name)
    let progress = LockIsolated<[HealthAppActionProgress]>([])
    let result = try await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, report in
        #expect(action == .export(to: downloads))
        report(.preparing)
        report(.downloading(1))
        return .exported(saved)
      }
    } operation: {
      try await ExportHealthDataIntent.export(to: downloads) { update in
        progress.withValue { $0.append(update) }
      }
    }
    #expect(result == saved)
    #expect(progress.value == [.preparing, .downloading(1)])
    let entries = try accessStore.entries()
    #expect(entries.map(\.command) == ["export ~/Downloads"])
    #expect(entries.map(\.process) == ["Shortcuts, Siri or Spotlight"])
    #expect(try ExportHealthDataIntent.folderURL(nil) == URL.downloadsDirectory)
  }

  @Test
  func failsWithSignInFirstWhenSignedOut() async throws {
    try accessStore.setEnabled(true)
    let folder = try makeFolder()
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    } operation: {
      await #expect(throws: HealthAppActionError.signedOut) {
        try await ExportHealthDataIntent.export(to: folder) { _ in }
      }
    }
    #expect(
      try accessStore.entries().map(\.command) == ["export \(HealthAppAction.displayPath(folder))"])
  }

  @Test(.timeLimit(.minutes(1)))
  func endedByTheSystemItSaysTheAppIsStillExporting() async throws {
    try accessStore.setEnabled(true)
    let folder = try makeFolder()
    let (started, start) = AsyncStream<Void>.makeStream()
    let exporting = withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { _, report in
        report(.preparing)
        start.yield()
        // The app keeps exporting past the intent.
        try await Task.sleep(for: .seconds(3_600))
        return .exported(folder.appending(path: name))
      }
    } operation: {
      Task { try await ExportHealthDataIntent.export(to: folder) { _ in } }
    }
    for await _ in started { break }
    exporting.cancel()
    await #expect(throws: HealthAppActionError.stillExporting(folderName: "Exports")) {
      try await exporting.value
    }
    #expect(
      HealthAppActionError.stillExporting(folderName: "Downloads").localizedDescription
        == "lil health is still exporting. It'll be saved to Downloads.")
  }
}

/// A request for `AppFeature`, its answer once given, and the progress it reported.
private func makeRequest(
  _ action: HealthAppAction
) -> (
  HealthAppActionRequest, () async throws -> HealthAppActionResult,
  LockIsolated<[HealthAppActionProgress]>
) {
  let progress = LockIsolated<[HealthAppActionProgress]>([])
  let (answers, answer) = AsyncStream<Result<HealthAppActionResult, any Error>>.makeStream()
  let request = HealthAppActionRequest(action: action) { update in
    progress.withValue { $0.append(update) }
  } reply: {
    answer.yield($0)
  }
  return (
    request,
    {
      for await result in answers { return try result.get() }
      throw CancellationError()
    },
    progress
  )
}
