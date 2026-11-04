import Dependencies
import Foundation
import HealthCardStore
import HealthCards
import HealthDatabase
import HealthUI
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthMacApp

/// Summary's headlines (851-3237): every card's in one read, followed while sync writes, at most
/// once a second, and fresh once it stops.
@Suite
struct CardHeadlinesRequestTests {
  private let steps = Card.welcomeSeed[0]

  /// Reordering cards is the same request, so Summary doesn't read them again; a new spec isn't.
  /// A card this version can't read has none.
  @Test
  func aRequestIsTheCardsSpecs() {
    let cards = Array(Card.welcomeSeed)
    #expect(
      CardHeadlinesRequest(cards: cards, day: previewNow)
        == CardHeadlinesRequest(cards: cards.reversed(), day: previewNow))
    var renamed = cards
    renamed[0].spec?.display.name = "Walking"
    #expect(
      CardHeadlinesRequest(cards: cards, day: previewNow)
        != CardHeadlinesRequest(cards: renamed, day: previewNow))
    #expect(
      CardHeadlinesRequest(cards: cards + [laterVersionCard], day: previewNow).specs.keys.sorted()
        == cards.map(\.id).sorted())
  }

  @Test
  func headlinesFollowWritesOncePerSecond() async throws {
    let database = try HealthDatabase.make()
    let clock = ManualClock()
    let request = CardHeadlinesRequest(cards: [steps], day: previewNow)
    let values = LockIsolated<[[Card.ID: CardRow.Headline]]>([])
    let task = Task {
      for await headlines in request.observe(
        in: database, clock: clock, now: { previewNow }, calendar: previewCalendar)
      {
        values.withValue { $0.append(headlines) }
      }
    }
    defer { task.cancel() }
    try await eventually { values.value == [[steps.id: .loaded(nil)]] }

    // A page of steps, then another, within the second: read once, after it.
    for minutes in [60, 30] { try write(steps: 100, minutesAgo: minutes, to: database) }
    try await clock.waitUntilAsleep(endingIn: .seconds(1))
    #expect(values.value.count == 1)
    clock.advance(by: .seconds(1))
    try await eventually { values.value.count == 2 }
    guard case .loaded(let headline?) = values.value.last?[steps.id] else {
      Issue.record("No headline: \(values.value)")
      return
    }
    #expect(headline.value == 200)
  }

  private func write(steps count: Double, minutesAgo: Int, to database: any DatabaseWriter)
    throws
  {
    let start = previewNow.addingTimeInterval(-Double(minutesAgo) * 60).unixMilliseconds
    try database.write { db in
      try HealthSample.insert {
        HealthSample(
          id: UUID().uuidString.lowercased(), type: "HKQuantityTypeIdentifierStepCount",
          startDate: start, endDate: start + 60_000, value: count, unit: "count",
          sourceName: "iPhone", sourceBundleID: "com.apple.health.phone")
      }
      .execute(db)
    }
  }
}
