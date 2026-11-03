import Foundation
import HealthCards
import HealthConformance
import HealthDatabase
import SQLiteData
import Testing

/// The Mac's side of the cards' conformance cases (851-3198, docs/decisions/cards.md ›
/// Conformance and tolerance): the cards' dataset (the Health tools', extended) synced into a
/// fresh database with the app's sync engine, as `HealthToolkitConformanceTests` syncs the tools',
/// then each case's spec run by the Mac's engine (`HealthDatabase.cardData`). Every case has to
/// pass, as on the server (`Services/api/test/health/cards/CardConformance.test.ts`).
@Suite
struct CardConformanceTests {
  @Test(arguments: try CardConformanceCase.cases())
  func conformanceCase(_ testCase: CardConformanceCase) async throws {
    let database = try DatabaseQueue()
    try HealthDatabase.migrator.migrate(database)
    try await Conformance.sync(try CardConformanceCase.dataset(), into: database)

    let calendar = try testCase.calendar()
    let spec = try testCase.cardSpec()
    let (range, date, now) = (
      try testCase.cardRange(), try testCase.day(in: calendar), try testCase.nowDate()
    )
    let data = try await database.read { db in
      try HealthDatabase.cardData(
        spec, range: range, date: date, now: now, calendar: calendar, db)
    }
    let output = testCase.json(data, calendar: calendar)
    #expect(output.matches(testCase.expected), "\(output)\nexpected:\n\(testCase.expected)")
  }
}
