import ComposableArchitecture
import CoreLocation
import DependenciesTestSupport
import Foundation
import HealthCatalog
import HealthDatabase
import LilAuth
import LilSync
import SQLiteData
import SwiftUI
import Testing

@testable import HealthMacApp

// Fresh app storage for each test: pins live there.
@Suite(.dependencies)
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
    await store.receive(\.signIn.readyToSignIn)
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
        push: { _ in },
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
    await store.receive(\.signIn.readyToSignIn)
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
    let respiratory = "HKQuantityTypeIdentifierRespiratoryRate"
    #expect(
      MetricFormat.value(15.5, unit: "count/min", typeID: respiratory).number == 15.5.formatted())
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
  func sixMonthsAcrossAYearNameBothYears() {
    let interval = ChartRange.sixMonths.interval(offset: -1, now: now, calendar: utc)
    let span = ChartFormat.span(interval, range: .sixMonths, calendar: utc)
    #expect(span.contains("2024") && span.contains("2025"))
    let current = ChartFormat.span(
      ChartRange.sixMonths.interval(offset: 0, now: now, calendar: utc), range: .sixMonths,
      calendar: utc)
    #expect(current.components(separatedBy: "2025").count == 2)
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

struct SampleFormatTests {
  @Test
  func metadataKeysReadAsWords() {
    #expect(SampleFormat.key("HKMetadataKeyHeartRateMotionContext") == "Heart Rate Motion Context")
    // Another app's key stays as it is.
    #expect(SampleFormat.key("com.example.reading") == "com.example.reading")
  }

  @Test
  func aMomentShowsItsTimeAndASpanBothEnds() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = 1_760_400_000_000
    let moment = HealthSample(
      id: "a", type: "x", startDate: start, endDate: start + 30_000, sourceName: "Test",
      sourceBundleID: "com.example")
    var span = moment
    span.endDate = start + 20 * 60_000
    let time = Date.FormatStyle(calendar: utc, timeZone: utc.timeZone).hour().minute()
    #expect(
      SampleFormat.time(moment, calendar: utc) == Date(unixMilliseconds: start).formatted(time))
    #expect(SampleFormat.time(span, calendar: utc) != SampleFormat.time(moment, calendar: utc))
  }
}

// Fresh app storage for each test: pins live there.
@Suite(.dependencies)
@MainActor
struct SummaryFeatureTests {
  private let steps = "HKQuantityTypeIdentifierStepCount"
  private let heartRate = "HKQuantityTypeIdentifierHeartRate"
  private let weight = "HKQuantityTypeIdentifierBodyMass"

  @Test
  func pinsUnpinsAndReordersThroughSync() async {
    let pushed = LockIsolated<[[SyncMutation]]>([])
    let store = TestStore(initialState: SummaryFeature.State(pins: [])) {
      SummaryFeature()
    } withDependencies: {
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    await store.send(.editButtonTapped) { $0.isEditing = true }
    await store.send(.pinButtonTapped(steps)) { $0.pins = [self.steps] }
    await store.send(.pinButtonTapped(heartRate)) { $0.pins = [self.steps, self.heartRate] }
    // Pinning twice doesn't duplicate it, or write anything.
    await store.send(.pinButtonTapped(steps))
    await store.send(.pinButtonTapped(weight)) {
      $0.pins = [self.steps, self.heartRate, self.weight]
    }
    await store.send(.pinsMoved([2], 0)) { $0.pins = [self.weight, self.steps, self.heartRate] }
    await store.send(.unpinButtonTapped(steps)) { $0.pins = [self.weight, self.heartRate] }
    await store.send(\.binding.search, "heart") { $0.search = "heart" }
    await store.send(.doneButtonTapped) {
      $0.isEditing = false
      $0.search = ""
    }
    await store.finish()
    #expect(
      pushed.value.last
        == HealthDatabase.pinMutations(
          from: [weight, steps, heartRate], to: [weight, heartRate]))
    #expect(pushed.value.count == 5)
  }

  @Test
  func readsThePinsFromTheSyncedTable() async throws {
    let database = try HealthDatabase.make()
    try await database.write { db in
      try HealthPin.insert {
        HealthPin(id: self.heartRate, position: 1)
        HealthPin(id: self.steps, position: 0)
      }
      .execute(db)
    }
    let store = TestStore(initialState: SummaryFeature.State()) {
      SummaryFeature()
    } withDependencies: {
      $0.defaultDatabase = database
    }
    #expect(store.state.isLoadingPins)
    let task = await store.send(.task)
    await store.receive(\.pinsLoaded) {
      $0.pins = [self.steps, self.heartRate]
      $0.isLoadingPins = false
    }
    // Another Mac's change arrives with sync.
    try await database.write { db in
      try HealthPin.find(self.steps).delete().execute(db)
    }
    await store.receive(\.pinsLoaded) { $0.pins = [self.heartRate] }
    await task.cancel()
  }

  @Test
  func closingTheEditorAnyWayClearsItsSearch() async {
    let store = TestStore(initialState: SummaryFeature.State(isEditing: true)) {
      SummaryFeature()
    }
    await store.send(\.binding.search, "sleep") { $0.search = "sleep" }
    // Esc, through the sheet's binding.
    await store.send(\.binding.isEditing, false) {
      $0.isEditing = false
      $0.search = ""
    }
  }

  @Test
  func duplicatedPinsShowOnceAndMoveAsShown() async {
    let state = SummaryFeature.State(pins: [steps, heartRate, steps, weight])
    #expect(state.orderedPins == [steps, heartRate, weight])
    let store = TestStore(initialState: state) {
      SummaryFeature()
    } withDependencies: {
      $0.sync.push = { _ in }
    }
    await store.send(.pinsMoved([2], 0)) { $0.pins = [self.weight, self.steps, self.heartRate] }
  }

  @Test
  func theEditorOffersWhatIsntPinnedMatchingTheSearch() {
    var state = SummaryFeature.State(pins: [heartRate])
    state.search = "heart rate"
    let names = state.unpinned.map(\.name)
    #expect(names.contains("Resting Heart Rate"))
    #expect(!names.contains("Heart Rate"))
    #expect(names.allSatisfy { $0.localizedStandardContains("heart rate") })
  }

  @Test
  func signingOutClearsThePins() async {
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
      $0.sync = .constant(.idle)
    }
    await store.send(.summary(.pinButtonTapped(steps))) { $0.summary.pins = [self.steps] }
    let task = await store.send(.task)
    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.summary = SummaryFeature.State()
    }
    await store.receive(\.signIn.readyToSignIn)
    session.finish()
    await task.finish()
    await store.finish()
  }
}

// Fresh app storage for each test: local pins live there.
@Suite(.dependencies)
@MainActor
struct PinMigrationTests {
  private let steps = "HKQuantityTypeIdentifierStepCount"
  private let heartRate = "HKQuantityTypeIdentifierHeartRate"

  private func store(
    database: any DatabaseWriter, pushed: LockIsolated<[[SyncMutation]]>
  ) -> TestStoreOf<AppFeature> {
    TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.defaultDatabase = database
      $0.sync = .constant(.idle)
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
  }

  @Test
  func thisMacsPinsMoveUpAfterTheFirstSync() async throws {
    @Shared(.summaryPins) var local = [steps, heartRate]
    let pushed = LockIsolated<[[SyncMutation]]>([])
    let store = store(database: try HealthDatabase.make(), pushed: pushed)
    let now = Date(timeIntervalSince1970: 1_760_400_000)
    await store.send(.syncStatusChanged(.upToDate(at: now))) {
      $0.syncStatus = .upToDate(at: now)
      $0.$localPins.withLock { $0 = [] }
    }
    await store.finish()
    #expect(pushed.value == [HealthDatabase.pinMutations(from: [], to: [steps, heartRate])])
    // Done with: a later sync doesn't push them again.
    await store.send(.syncStatusChanged(.upToDate(at: now)))
    #expect(pushed.value.count == 1)
  }

  @Test
  func anAccountWithPinsKeepsThem() async throws {
    @Shared(.summaryPins) var local = [steps]
    let database = try HealthDatabase.make()
    try await database.write { db in
      try HealthPin.insert { HealthPin(id: self.heartRate, position: 0) }.execute(db)
    }
    let pushed = LockIsolated<[[SyncMutation]]>([])
    let store = store(database: database, pushed: pushed)
    let now = Date(timeIntervalSince1970: 1_760_400_000)
    await store.send(.syncStatusChanged(.upToDate(at: now))) {
      $0.syncStatus = .upToDate(at: now)
      $0.$localPins.withLock { $0 = [] }
    }
    await store.finish()
    #expect(pushed.value.isEmpty)
  }
}

struct HighlightTextTests {
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let resting = HealthCatalog.type(id: "HKQuantityTypeIdentifierRestingHeartRate")!

  @Test
  func weeksSayWhichWayTheyWent() {
    let up = Highlight(
      typeID: steps.id, kind: .week, current: 8_000, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(up, type: steps).contains("a day"))
    #expect(HighlightText.sentence(up, type: steps).contains("up from"))
    let same = Highlight(
      typeID: steps.id, kind: .week, current: 7_100, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(same, type: steps).contains("about the same"))
  }

  @Test
  func fromNothingIsAChange() {
    let exercise = HealthCatalog.type(id: "HKQuantityTypeIdentifierAppleExerciseTime")!
    let fromZero = Highlight(
      typeID: exercise.id, kind: .week, current: 30, previous: 0, recentStart: .now)
    #expect(fromZero.direction == .up)
    #expect(HighlightText.sentence(fromZero, type: exercise).contains("up from 0 min"))
  }

  @Test
  func eachValueKeepsItsOwnUnit() {
    let distance = HealthCatalog.type(id: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
    let highlight = Highlight(
      typeID: distance.id, kind: .week, current: 5_200, previous: 950, recentStart: .now)
    let sentence = HighlightText.sentence(highlight, type: distance)
    #expect(sentence.contains("km a day"))
    #expect(sentence.contains("950 m"))
  }

  @Test
  func trendsFollowTheValues() {
    let down = Highlight(
      typeID: resting.id, kind: .trend, current: 58, previous: 66, recentStart: .now)
    #expect(down.direction == .down)
    #expect(HighlightText.sentence(down, type: resting).contains("trending down"))
    // A discrete type's average isn't per day.
    #expect(!HighlightText.sentence(down, type: resting).contains("a day"))
  }
}

struct SleepFormatTests {
  @Test
  func durationsReadLikeHealth() {
    #expect(SleepFormat.duration(45 * 60) == "45 min")
    #expect(SleepFormat.duration(7 * 3600) == "7 hr")
    #expect(SleepFormat.duration(7 * 3600 + 32 * 60) == "7 hr 32 min")
  }

  @Test
  func rowsFollowWhatTheSourceRecorded() {
    let day = Date(timeIntervalSince1970: 1_760_400_000)
    let staged = SleepNight(
      day: day, segments: [SleepSegment(stage: .deep, start: day, end: day + 60)], inBed: 60)
    #expect(SleepFormat.rows(for: staged) == [.awake, .rem, .core, .deep])
    let estimated = SleepNight(
      day: day, segments: [SleepSegment(stage: .asleep, start: day, end: day + 60)], inBed: 60)
    #expect(SleepFormat.rows(for: estimated) == [.awake, .asleep])
    // A staged night with some unspecified sleep too shows it as its own row.
    let mixed = SleepNight(
      day: day,
      segments: [
        SleepSegment(stage: .deep, start: day, end: day + 60),
        SleepSegment(stage: .asleep, start: day + 60, end: day + 120),
      ], inBed: 120)
    #expect(SleepFormat.rows(for: mixed) == [.awake, .rem, .core, .deep, .asleep])
  }
}

struct WorkoutFormatTests {
  @Test
  func timesAndPacesReadLikeHealth() {
    #expect(WorkoutFormat.duration(42 * 60 + 18) == "42:18")
    #expect(WorkoutFormat.duration(3600 + 2 * 60 + 5) == "1:02:05")
    #expect(WorkoutFormat.pace(5 * 60 + 12) == "5'12\"/km")
    #expect(WorkoutActivity.name(37) == "Running")
    #expect(WorkoutActivity.name(9_999) == "Workout")
  }

  // Main actor: resolving a SwiftUI color to an NSColor needs it.
  @Test @MainActor
  func theRouteIsGreenWhereFastAndRedWhereSlow() {
    // Synthetic: fast for the first half, slow for the second.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let locations = (0..<200).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 100 ? 5 : 2)
    }
    let pieces = RouteMap.pieces(locations)
    #expect(pieces.count > 10)
    // Every location is in a piece, and pieces join end to start.
    #expect(pieces.first?.coordinates.first?.longitude == 0)
    #expect(pieces.last?.coordinates.last?.longitude == locations.last?.longitude)
    let hue = { (color: Color) in NSColor(color).usingColorSpace(.deviceRGB)?.hueComponent ?? -1 }
    #expect(hue(pieces.first!.color) > 0.3)
    // Unknown speeds aren't slow.
    let unknown = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index.isMultiple(of: 2) ? -1 : 5)
    }
    let known = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 25 ? 2 : 5)
    }
    let mixed = RouteMap.pieces(known + unknown)
    #expect(hue(mixed.last!.color) > 0.3)
    // Red's hue is 0, or 1 as it wraps around.
    let slow = hue(pieces.last!.color)
    #expect(min(slow, 1 - slow) < 0.05)
  }
}

struct WorkoutHeartRateTests {
  // Main actor: it's the view's.
  @Test @MainActor
  func theChartUsesTheMainSource() {
    let sample = { (source: String, value: Double) in
      HealthSample(
        id: UUID().uuidString, type: "HKQuantityTypeIdentifierHeartRate", startDate: 0,
        endDate: 0, value: value, unit: "count/min", sourceName: source, sourceBundleID: source)
    }
    let samples = [
      sample("watch", 150), sample("strap", 90), sample("watch", 152), sample("watch", 149),
    ]
    #expect(WorkoutDetailView.mainSource(samples).map(\.value) == [150, 152, 149])
  }
}
