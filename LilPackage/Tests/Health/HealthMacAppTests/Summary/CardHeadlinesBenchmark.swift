import Dependencies
import Foundation
import HealthCardStore
import HealthCards
import HealthDatabase
import SQLiteData
import Synchronization
import Testing

@testable import HealthMacApp

/// Summary's card headlines while sync writes (851-3237): the catalog database on disk, with 20
/// and 100 cards (the welcome seed and the design's example cards, again and again), and a
/// backfill of 60 pages of 1,000 readings, each page a write transaction, back to back as a first
/// sync's are. It prints how many headlines ran, their CPU time, the process's, and how long the
/// writes took. Run in Release with
/// `LIL_BENCHMARKS=1 scripts/swift test -c release --filter CardHeadlinesBenchmark`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LIL_BENCHMARKS"] == "1"))
struct CardHeadlinesBenchmark {
  @Test(arguments: [0, 20, 100])
  @MainActor
  func rowsFetchingTheirOwn(cards: Int) async throws {
    let (database, url) = try Self.database()
    defer { Self.remove(url) }
    let counter = HeadlineCounter()
    let fetches = withDependencies {
      $0.date = .constant(previewNow)
      $0.calendar = previewCalendar
    } operation: {
      Self.cards(cards).map { card in
        Fetch(
          wrappedValue: nil, CountingHeadlineRequest(spec: card.spec!, counter: counter),
          database: database, scheduler: MainQueueScheduler())
      }
    }
    try await Self.waitForQuiet(counter)
    let first = counter.runs
    let measured = try await Self.backfill(database, counter: counter)
    print(
      "Rows fetching their own, \(cards) cards: first \(first) runs; during the backfill \(measured)"
    )
    withExtendedLifetime(fetches) {}
  }

  @Test(arguments: [20, 100])
  @MainActor
  func oneThrottledRequest(cards: Int) async throws {
    let (database, url) = try Self.database()
    defer { Self.remove(url) }
    let counter = HeadlineCounter()
    let request = CardHeadlinesRequest(cards: Self.cards(cards), day: previewNow)
    let stream = throttledObservation(
      of: HealthDatabase.cardTables, in: database, clock: ContinuousClock()
    ) { db in
      counter.measure(runs: request.specs.count) {
        request.fetch(now: previewNow, calendar: previewCalendar, db)
      }
    }
    let task = Task { for await _ in stream {} }
    defer { task.cancel() }
    try await Self.waitForQuiet(counter)
    let first = counter.runs
    let measured = try await Self.backfill(database, counter: counter)
    print(
      "One throttled request, \(cards) cards: first \(first) runs; during the backfill \(measured)"
    )
  }

  // MARK: - Setup

  /// The specs: the welcome seed's and the example cards', each with its own name, so no two rows
  /// share a request.
  static func cards(_ count: Int) -> [Card] {
    let specs = Card.welcomeSeed.compactMap(\.spec) + exampleCards.compactMap(\.spec)
    return (0..<count).map { index in
      var spec = specs[index % specs.count]
      spec.display.name = "Card \(index)"
      return Card(
        id: "card_bench_\(index)", spec: spec, position: "a\(index)", createdAt: 0, updatedAt: 0)
    }
  }

  /// The example cards' database (the catalog's, with readings before sleep), copied to disk, as
  /// the app's is: a pool, whose reads don't wait for its writes.
  static func database() throws -> (any DatabaseWriter, URL) {
    let url = URL.temporaryDirectory.appending(
      path: "card-headlines-\(UUID().uuidString).sqlite")
    let database = try HealthDatabase.make(at: url)
    try exampleCardsDatabase.backup(to: database)
    return (database, url)
  }

  static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
    }
  }

  struct Measured: CustomStringConvertible {
    var runs: Int
    var headlineCPU: Double
    var processCPU: Double
    var writes: Double
    var settled: Double

    var description: String {
      String(
        format:
          "%d headline runs, %.0f ms of their CPU; process CPU %.0f ms; writes took %.0f ms, last headline %.0f ms after",
        runs, headlineCPU, processCPU, writes, settled)
    }
  }

  /// Writes 60 pages of 1,000 heart rate and step readings in the 3 days to `previewNow`, then
  /// waits until headlines stop running.
  static func backfill(_ database: any DatabaseWriter, counter: HeadlineCounter) async throws
    -> Measured
  {
    let (runs, cpu) = (counter.runs, counter.cpuMilliseconds)
    let processStart = processCPUMilliseconds()
    let start = ContinuousClock.now
    let pages = 60
    let perPage = 1_000
    let first = previewNow.unixMilliseconds - pages * perPage * 4_000
    for page in 0..<pages {
      try await database.write { db in
        try HealthSample.insert {
          (0..<perPage).map { index in
            let at = first + (page * perPage + index) * 4_000
            let isHeartRate = index.isMultiple(of: 2)
            return HealthSample(
              id: UUID().uuidString.lowercased(),
              type: isHeartRate
                ? HealthDatabase.heartRateType : "HKQuantityTypeIdentifierStepCount",
              startDate: at, endDate: at + 4_000, value: isHeartRate ? 70 : 12,
              unit: isHeartRate ? "count/min" : "count", sourceName: "Apple Watch",
              sourceBundleID: "com.apple.health.watch")
          }
        }
        .execute(db)
      }
    }
    let written = ContinuousClock.now
    try await waitForQuiet(counter)
    return Measured(
      runs: counter.runs - runs, headlineCPU: counter.cpuMilliseconds - cpu,
      processCPU: processCPUMilliseconds() - processStart,
      writes: (written - start).milliseconds,
      settled: max(.zero, counter.lastEnd - written).milliseconds)
  }

  /// How long no headline runs before they count as settled.
  static let quiet = Duration.milliseconds(1_500)

  /// Waits until no headline has run for `quiet`.
  static func waitForQuiet(_ counter: HeadlineCounter) async throws {
    var last = counter.runs
    while true {
      try await Task.sleep(for: quiet)
      if counter.runs == last { return }
      last = counter.runs
    }
  }

  static func processCPUMilliseconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
  }
}

/// Counts headline runs, and their CPU time.
final class HeadlineCounter: Sendable {
  private let state = Mutex((runs: 0, cpu: 0.0, lastEnd: ContinuousClock.now))

  var runs: Int { state.withLock { $0.runs } }
  var cpuMilliseconds: Double { state.withLock { $0.cpu } }
  /// When the last run ended.
  var lastEnd: ContinuousClock.Instant { state.withLock { $0.lastEnd } }

  /// Runs `body`, which runs `runs` headlines.
  func measure<T>(runs: Int = 1, _ body: () throws -> T) rethrows -> T {
    let start = Self.threadCPUMilliseconds()
    defer {
      let cpu = Self.threadCPUMilliseconds() - start
      state.withLock {
        $0.runs += runs
        $0.cpu += cpu
        $0.lastEnd = .now
      }
    }
    return try body()
  }

  private static func threadCPUMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
  }
}

/// Summary's request before 851-3237, a row's own (`nil` until fetched), counted.
private struct CountingHeadlineRequest: FetchKeyRequest, Hashable {
  let spec: CardSpec
  let counter: HeadlineCounter

  func fetch(_ db: Database) throws -> CardHeadline?? {
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return try counter.measure {
      try HealthDatabase.cardHeadline(spec, now: now, calendar: calendar, db)
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.spec == rhs.spec }
  func hash(into hasher: inout Hasher) { hasher.combine(spec) }
}

extension Duration {
  fileprivate var milliseconds: Double {
    Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
  }
}
