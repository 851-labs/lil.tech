import Dependencies
import Foundation
import GRDB
import HealthCardStore
import HealthCards
import HealthCatalog
import HealthDatabase
import SQLiteData
import Synchronization
import Testing

@testable import HealthMacApp

/// The pages that follow sync with `ThrottledFetch` (851-4045) observe `HealthDatabase.dataTables`:
/// every table their requests read is one of them, on the catalogs' demo data, or a page would
/// miss what sync writes there. Summary's highlights, Metric Detail, the categories and a card's
/// page.
@Suite
struct DataTablesTests {
  @Test
  func highlights() async throws {
    try await expectCovered(HighlightsRequest(day: previewNow))
  }

  @Test(
    arguments: HealthCatalog.all.filter { type in
      type.kind == .quantity || HealthDatabase.categoryChartTypes.contains(type.id)
    })
  func metricDetail(type: HealthDataType) async throws {
    for range in ChartRange.allCases {
      try await expectCovered(MetricChartRequest(typeID: type.id, range: range, offset: 0))
    }
  }

  @Test(arguments: HealthCategory.allCases)
  func category(_ category: HealthCategory) async throws {
    try await expectCovered(CategorySummaries(category: category))
  }

  /// A card's page, for the welcome seed and the design's example cards, on their data.
  @Test(arguments: Card.welcomeSeed + exampleCards)
  func cardPage(_ card: Card) async throws {
    let spec = try #require(card.spec)
    for range in CardRange.allCases {
      try await expectCovered(
        CardDataRequest(spec: spec, range: range, offset: 0), in: exampleCardsDatabase)
    }
  }

  private func expectCovered<Request: FetchKeyRequest>(
    _ request: Request, in database: any DatabaseWriter = catalogDatabase,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws where Request.Value: Sendable {
    let declared = try await database.read { db in
      try HealthDatabase.dataTables.reduce(DatabaseRegion()) { $0.union(try $1.databaseRegion(db)) }
    }
    let read = Mutex(DatabaseRegion())
    let observation = withDependencies {
      $0.date = .constant(previewNow)
      $0.calendar = previewCalendar
    } operation: {
      withEscapedDependencies { dependencies in
        ValueObservation.tracking { db in
          try dependencies.yield { try request.fetch(db) }
        }
      }
    }
    .handleEvents(willTrackRegion: { region in read.withLock { $0.formUnion(region) } })
    for try await _ in observation.values(in: database) { break }
    let region = read.withLock { $0 }
    #expect(
      declared.union(region) == declared, "\(request) reads \(region)",
      sourceLocation: sourceLocation)
  }
}
