import ComposableArchitecture
import Foundation
import HealthCardStore
import HealthCards
import HealthKitAccess
import HealthUI
import Testing

@testable import HealthPhoneApp

// Where a card's page opens (851-3212): on the latest data its Summary row found, when the row ran
// the card as it is now, and for a week across a month's end, on the month with its readings
// (851-4040). Synthetic data only.
struct CardPageTests {
  private let steps = Card.welcomeSeed[0].spec!
  private let day = Date(timeIntervalSince1970: 1_723_532_400)

  private func kept(_ spec: CardSpec?, _ headline: CardRow.Headline)
    -> (run: CardHeadlines.Run, headline: CardRow.Headline)
  {
    (CardHeadlines.Run(spec: spec, day: day, generation: 0, needsHealthAccess: false), headline)
  }

  private func headline(at date: Date) -> CardHeadline {
    CardHeadline(
      value: 8_000, date: date, kind: .bucket,
      data: CardData(
        range: nil, interval: DateInterval(start: date, duration: 86_400), bucket: .auto,
        grain: .day,
        series: [], formulas: [], summary: nil, goal: nil))
  }

  @Test
  func opensOnTheRowsHeadline() {
    let latest = Date(timeIntervalSince1970: 1_722_000_000)
    #expect(
      CardOpening(kept(steps, .loaded(headline(at: latest))), spec: steps)
        == .latest(CardOpening.Latest(date: latest, grain: .day)))
    // No Data: the current period.
    #expect(CardOpening(kept(steps, .loaded(nil)), spec: steps) == .latest(nil))
  }

  @Test
  func looksItselfWhenTheRowHasNoHeadlineForTheCardAsItIs() {
    #expect(CardOpening(nil, spec: steps) == .unknown)
    #expect(CardOpening(kept(steps, .loading), spec: steps) == .unknown)
    #expect(CardOpening(kept(steps, .failed("Locked.")), spec: steps) == .unknown)
    // The row's headline is of the card before an edit.
    var edited = steps
    edited.range = .month
    #expect(
      CardOpening(kept(steps, .loaded(headline(at: day))), spec: edited) == .unknown)
  }

  // MARK: - A week across a month's end (851-4040)

  /// London, weeks from Monday.
  private static let london: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.firstWeekday = 2
    return calendar
  }()

  private static func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    london.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  /// Wednesday Nov 4: the week of Monday Oct 26 ran to Sunday Nov 1.
  private let now = date(11, 4, 12)

  /// Steps by the week, opening on a month.
  private var weekly: CardSpec {
    var spec = steps
    spec.bucket = .week
    spec.range = .month
    return spec
  }

  /// Cards whose every period is a week of steps with a point at each of `weeks`' starts, which
  /// records the dates it was run for.
  private func cards(weeks: [Date], runs: LockIsolated<[Date]>) -> HealthKitCards {
    HealthKitCards(
      data: { _, range, date, now, calendar in
        runs.withValue { $0.append(date) }
        let interval = range.interval(
          offset: range.offset(containing: date, now: now, calendar: calendar), now: now,
          calendar: calendar)
        return CardData(
          range: range, interval: interval, bucket: .week, grain: .week,
          series: [
            CardData.Series(
              id: "steps", label: "Steps", type: "HKQuantityTypeIdentifierStepCount",
              aggregation: .sum, unit: .catalog("count"), hidden: false,
              points: weeks.map { CardPoint(start: $0, value: 20_000) })
          ],
          formulas: [], summary: nil, goal: nil)
      },
      headline: { _, _, _ in
        Issue.record("Opening on a headline ran the headline.")
        return nil
      })
  }

  @Test
  func aWeekAcrossAMonthsEndOpensOnTheLaterMonthWhenItHasTheWeek() async throws {
    let week = Self.date(10, 26)
    let latest = CardOpening.Latest(date: week, grain: .week)
    // The week straddles October and November: the page runs November before it opens.
    #expect(CardOpening.latest(latest).offset(in: .month, now: now, calendar: Self.london) == nil)
    #expect(
      latest.openingDates(in: .month, now: now, calendar: Self.london)
        == [Self.date(11, 2) - 0.001, week])

    // November counts the week's readings from Sunday Nov 1: it has the week's point, and the
    // page draws the data it ran.
    let runs = LockIsolated<[Date]>([])
    let november = try await CardOpening.opened(
      at: latest, spec: weekly, range: .month, now: now, calendar: Self.london,
      in: cards(weeks: [week], runs: runs))
    #expect(runs.value == [Self.date(11, 2) - 0.001])
    #expect(november.date == Self.date(11, 2) - 0.001)
    #expect(november.data?.interval.start == Self.date(11, 1))
    #expect(
      CardRange.month.openingOffset(latest: november.date, now: now, calendar: Self.london) == 0)

    // November has none of the week's readings (they were all before Nov 1): October, which the
    // page runs itself.
    let october = try await CardOpening.opened(
      at: latest, spec: weekly, range: .month, now: now, calendar: Self.london,
      in: cards(weeks: [], runs: LockIsolated([])))
    #expect(october == CardOpening.Opened(date: week, data: nil))
    #expect(
      CardRange.month.openingOffset(latest: october.date, now: now, calendar: Self.london) == -1)

    // November's run fails: October, whose own run says what failed, with ‹ and › on.
    let failed = try await CardOpening.opened(
      at: latest, spec: weekly, range: .month, now: now, calendar: Self.london,
      in: HealthKitCards(
        data: { _, _, _, _, _ in throw HealthAccessNeeded() },
        headline: { _, _, _ in nil }))
    #expect(failed == CardOpening.Opened(date: week, data: nil))
  }

  @Test
  func aWeekInOneMonthOpensOnItWithoutARun() async throws {
    let week = Self.date(10, 19)
    let latest = CardOpening.Latest(date: week, grain: .week)
    #expect(CardOpening.latest(latest).offset(in: .month, now: now, calendar: Self.london) == -1)
    let runs = LockIsolated<[Date]>([])
    let opened = try await CardOpening.opened(
      at: latest, spec: weekly, range: .month, now: now, calendar: Self.london,
      in: cards(weeks: [week], runs: runs))
    #expect(opened == CardOpening.Opened(date: week, data: nil))
    #expect(runs.value.isEmpty)
    // No Data: the current period, at once.
    #expect(CardOpening.latest(nil).offset(in: .month, now: now, calendar: Self.london) == 0)
    #expect(CardOpening.unknown.offset(in: .month, now: now, calendar: Self.london) == nil)
  }
}
