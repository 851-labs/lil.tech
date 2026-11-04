import Dependencies
import Foundation
import HealthCardStore
import HealthCards
import HealthCatalog
import SQLiteData
import Testing

@testable import HealthDatabase
@testable import HealthMacApp
@testable import HealthPages

/// Summary's highlights and the pages' fetches while sync writes (851-4045), as
/// `CardHeadlinesBenchmark` measures the cards' headlines: the same database on disk and the same
/// backfill of 60 pages of 1,000 heart rate and step readings, with one page's fetch observed
/// three ways: not at all, by `@Fetch` (which GRDB runs again on the writer inside every commit),
/// and by `ThrottledFetch`. Run in Release with
/// `LIL_BENCHMARKS=1 scripts/swift test -c release --filter PageFetchesBenchmark`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LIL_BENCHMARKS"] == "1"))
struct PageFetchesBenchmark {
  enum Page: String, CaseIterable, CustomTestStringConvertible {
    case highlights
    case heartRateYear
    case stepsYear
    case heartCategory
    case activityCategory
    case sleepSixMonths
    case sleepHighlights
    case workouts
    case heartRateCardYear

    var testDescription: String { rawValue }
  }

  enum Observer: String, CaseIterable, CustomTestStringConvertible {
    case none
    case fetch
    case throttled

    var testDescription: String { rawValue }
  }

  @Test(arguments: Page.allCases, Observer.allCases)
  @MainActor
  func backfill(page: Page, observer: Observer) async throws {
    let (database, url) = try CardHeadlinesBenchmark.database()
    defer { CardHeadlinesBenchmark.remove(url) }
    let counter = HeadlineCounter()
    let observation = withDependencies {
      $0.date = .constant(previewNow)
      $0.calendar = previewCalendar
      $0.defaultDatabase = database
      $0.continuousClock = ContinuousClock()
    } operation: {
      Self.observe(page, by: observer, in: database, counter: counter)
    }
    defer { observation.cancel() }
    try await CardHeadlinesBenchmark.waitForQuiet(counter)
    let first = counter.runs
    let measured = try await CardHeadlinesBenchmark.backfill(database, counter: counter)
    print(
      "\(page.rawValue), \(observer.rawValue): first \(first) runs; during the backfill \(measured)"
    )
  }

  /// Something observing, until cancelled.
  struct Observation {
    var cancel: () -> Void
  }

  @MainActor
  static func observe(
    _ page: Page, by observer: Observer, in database: any DatabaseWriter, counter: HeadlineCounter
  ) -> Observation {
    switch page {
    case .highlights:
      observe(HighlightsRequest(day: previewNow), [], observer, database, counter)
    case .heartRateYear:
      observe(
        MetricChartRequest(typeID: HealthDatabase.heartRateType, range: .year, offset: 0), nil,
        observer, database, counter)
    case .stepsYear:
      observe(
        MetricChartRequest(
          typeID: "HKQuantityTypeIdentifierStepCount", range: .year, offset: 0), nil, observer,
        database, counter)
    case .heartCategory:
      observe(CategorySummaries(category: .heart), [], observer, database, counter)
    case .activityCategory:
      observe(CategorySummaries(category: .activity), [], observer, database, counter)
    case .sleepSixMonths:
      observe(
        SleepRequest(range: .sixMonths, offset: 0, day: previewNow, calendar: previewCalendar),
        nil, observer, database, counter)
    case .sleepHighlights:
      observe(
        SleepHighlightsRequest(day: previewNow, calendar: previewCalendar), nil, observer,
        database, counter)
    case .workouts:
      observe(RecentWorkouts(), WorkoutList(), observer, database, counter)
    case .heartRateCardYear:
      observe(
        CardDataRequest(
          spec: Card.welcomeSeed.compactMap(\.spec)[1], range: .year, offset: 0), nil, observer,
        database, counter)
    }
  }

  @MainActor
  private static func observe<Request: FetchKeyRequest>(
    _ request: Request, _ initial: Request.Value, _ observer: Observer,
    _ database: any DatabaseWriter, _ counter: HeadlineCounter
  ) -> Observation where Request.Value: Sendable {
    let counting = Counting(base: request, counter: counter)
    switch observer {
    case .none:
      // One read, as a page that doesn't follow sync would make.
      let task = Task { _ = try await database.read { try counting.fetch($0) } }
      return Observation { task.cancel() }
    case .fetch:
      let fetch = Fetch(
        wrappedValue: initial, counting, database: database, scheduler: MainQueueScheduler())
      return Observation { withExtendedLifetime(fetch) {} }
    case .throttled:
      // As the page's `ThrottledFetch` does.
      let model = ThrottledFetchModel<Request.Value>(value: initial, isLoading: true)
      model.follow(ThrottledFetchModel.Request(counting, tables: HealthDatabase.dataTables))
      return Observation { withExtendedLifetime(model) {} }
    }
  }
}

/// A request whose fetches `counter` counts and times.
private struct Counting<Base: FetchKeyRequest>: FetchKeyRequest {
  let base: Base
  let counter: HeadlineCounter

  func fetch(_ db: Database) throws -> Base.Value {
    try counter.measure { try base.fetch(db) }
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.base == rhs.base }
  func hash(into hasher: inout Hasher) { hasher.combine(base) }
}
