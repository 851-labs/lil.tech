import ComposableArchitecture
import Foundation
import HealthCatalog
import LilAuth
import LilSync
import Testing

@testable import HealthMacApp

@MainActor
struct AppFeatureTests {
  @Test
  func followsTheSessionAndStartsAfreshAfterSigningOut() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
      $0.sync = .constant(.idle)
    }

    let task = await store.send(.task)
    continuation.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    await store.receive(\.syncStatusChanged)
    await store.send(\.binding.selection, .category(.heart)) {
      $0.selection = .category(.heart)
    }
    await store.send(\.binding.searchText, "steps") {
      $0.searchText = "steps"
    }
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.selection = .summary
      $0.searchText = ""
    }
    await task.cancel()
    // Deleting the local data.
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func syncsWhileSignedInAndDeletesTheLocalDataOnSigningOut() async throws {
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let (statuses, status) = AsyncStream<SyncStatus>.makeStream()
    let events = LockIsolated<[String]>([])
    // A cached blob, which goes with the account.
    let blobs = URL.temporaryDirectory.appending(path: "BlobCache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: blobs.appending(path: "blob"))
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
      $0.sync = SyncClient(
        run: {
          events.withValue { $0.append("run") }
          try? await Task.sleep(for: .seconds(3600))
          events.withValue { $0.append("run ended") }
        },
        listen: { _ in
          events.withValue { $0.append("listen") }
          try? await Task.sleep(for: .seconds(3600))
          events.withValue { $0.append("listen ended") }
        },
        syncNow: {},
        status: { statuses },
        removeLocalData: { events.withValue { $0.append("removed") } })
      $0.blobCache = BlobCache(
        directory: blobs, maxBytes: 1 << 20, url: { _ in throw CancellationError() },
        download: .testValue)
    }

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    let syncedAt = Date(timeIntervalSince1970: 1_760_400_000)
    status.yield(.upToDate(at: syncedAt))
    await store.receive(\.syncStatusChanged) {
      $0.syncStatus = .upToDate(at: syncedAt)
    }
    #expect(Set(events.value) == ["run", "listen"])

    // Try Again starts a new pull.
    await store.send(.retrySyncButtonTapped)
    while events.value.filter({ $0 == "run" }).count < 2 { await Task.yield() }
    #expect(events.value.contains("run ended"))
    // Hearing again that it's signed in doesn't start another sync.
    session.yield(true)
    await store.receive(\.signedInChanged)

    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.syncStatus = .idle
    }
    session.finish()
    await task.finish()
    await store.finish()
    // Stopped, and the local data deleted. The engine makes the deletion wait for a pull being
    // cancelled (`LilSyncEngine.removeLocalData()`).
    #expect(events.value.filter { $0 == "run" }.count == 2)
    #expect(events.value.filter { $0 == "run ended" }.count == 2)
    #expect(events.value.contains("listen ended"))
    #expect(events.value.contains("removed"))
    #expect(!FileManager.default.fileExists(atPath: blobs.path(percentEncoded: false)))
  }

  @Test
  func signOutEndsTheSession() async {
    let signedOut = LockIsolated(false)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.auth.signOut = { signedOut.setValue(true) }
    }
    await store.send(.signOutButtonTapped)
    await store.finish()
    #expect(signedOut.value)
  }

  @Test
  func searchFindsDataTypesByName() {
    var state = AppFeature.State(isSignedIn: true)
    #expect(state.searchResults.isEmpty)

    state.searchText = "  heart rate  "
    let names = state.searchResults.map(\.name)
    #expect(names.contains("Heart Rate"))
    #expect(names.allSatisfy { $0.localizedStandardContains("heart rate") })
    // In the sidebar's category order.
    let categories = state.searchResults.compactMap(\.category)
    #expect(
      categories
        == categories.sorted {
          HealthCategory.allCases.firstIndex(of: $0)! < HealthCategory.allCases.firstIndex(of: $1)!
        })

    state.searchText = "xylophone"
    #expect(state.searchResults.isEmpty)
    // Spaces alone aren't a search.
    state.searchText = "   "
    #expect(state.query.isEmpty)
  }

  @Test
  func searchCoversEveryVersionButNotCharacteristics() {
    let state = AppFeature.State(isSignedIn: true, searchText: "menopause")
    // Added in iOS 27, and synced from iPhones that have it.
    #expect(!state.searchResults.isEmpty)
    #expect(AppFeature.State(isSignedIn: true, searchText: "blood type").searchResults.isEmpty)
  }

  @Test
  func clearingTheSearchSelectsTheFoundTypesCategory() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
        searchText: "heart")
    ) {
      AppFeature()
    }
    await store.send(\.binding.searchText, "") {
      $0.searchText = ""
      $0.selection = .category(.heart)
    }
  }
}

struct MetricFormatTests {
  private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2025-10-15 12:00 UTC, a Wednesday.
  private let now = Date(timeIntervalSince1970: 1_760_529_600)

  @Test
  func valuesInHealthsUnits() {
    let steps = MetricFormat.value(8214, unit: "count", typeID: "HKQuantityTypeIdentifierStepCount")
    #expect(steps.unit == "steps")
    #expect(steps.number == 8214.formatted(.number.precision(.fractionLength(0))))
    #expect(MetricFormat.value(0.97, unit: "%", typeID: "x").unit == "%")
    #expect(MetricFormat.value(0.97, unit: "%", typeID: "x").number == 97.formatted())
    #expect(MetricFormat.value(62, unit: "count/min", typeID: "x").unit == "BPM")
    // Whole numbers for BPM, as Health shows them; decimals for small values otherwise.
    #expect(MetricFormat.value(56.6, unit: "count/min", typeID: "x").number == 57.formatted())
    #expect(MetricFormat.value(4.51, unit: "L", typeID: "x").number == 4.51.formatted())
    #expect(
      MetricFormat.value(
        15, unit: "count/min", typeID: "HKQuantityTypeIdentifierRespiratoryRate"
      ).unit == "breaths/min")
    #expect(MetricFormat.value(5_300, unit: "m", typeID: "x").unit == "km")
    #expect(MetricFormat.value(420, unit: "m", typeID: "x").unit == "m")
    #expect(MetricFormat.value(36.6, unit: "degC", typeID: "x").unit == "°C")
    let cadence = "HKQuantityTypeIdentifierCyclingCadence"
    #expect(MetricFormat.value(85, unit: "count/min", typeID: cadence).unit == "RPM")
    let swimming = "HKQuantityTypeIdentifierDistanceSwimming"
    #expect(MetricFormat.value(1_500, unit: "m", typeID: swimming).unit == "m")
    let walking = "HKQuantityTypeIdentifierWalkingSpeed"
    #expect(MetricFormat.value(1.2, unit: "m/s", typeID: walking).unit == "km/h")
    let stairs = "HKQuantityTypeIdentifierStairAscentSpeed"
    #expect(MetricFormat.value(0.5, unit: "m/s", typeID: stairs).unit == "m/s")
    #expect(MetricFormat.value(1, unit: "mg/dL", typeID: "x").unit == "mg/dL")
  }

  @Test
  func datesLikeHealth() {
    let date = { (daysAgo: Double) in self.now.addingTimeInterval(-daysAgo * 86_400) }
    let style = Date.FormatStyle(calendar: utc, timeZone: utc.timeZone)
    #expect(MetricFormat.date(date(0), isDay: true, now: now, calendar: utc) == "Today")
    #expect(MetricFormat.date(date(0), isDay: false, now: now, calendar: utc) != "Today")
    #expect(MetricFormat.date(date(1), isDay: true, now: now, calendar: utc) == "Yesterday")
    #expect(
      MetricFormat.date(date(3), isDay: true, now: now, calendar: utc)
        == date(3).formatted(style.weekday(.wide)))
    #expect(
      MetricFormat.date(date(30), isDay: true, now: now, calendar: utc)
        == date(30).formatted(style.month(.abbreviated).day()))
    #expect(
      MetricFormat.date(date(400), isDay: true, now: now, calendar: utc)
        == date(400).formatted(style.month(.abbreviated).day().year()))
  }
}
