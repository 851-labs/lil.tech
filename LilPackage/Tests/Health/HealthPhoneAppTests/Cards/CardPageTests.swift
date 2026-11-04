import Foundation
import HealthCardStore
import HealthCards
import HealthUI
import Testing

@testable import HealthPhoneApp

// Where a card's page opens (851-3212): on the latest data its Summary row found, when the row ran
// the card as it is now. Synthetic data only.
struct CardPageTests {
  private let steps = Card.welcomeSeed[0].spec!
  private let day = Date(timeIntervalSince1970: 1_723_532_400)

  private func kept(_ spec: CardSpec?, _ headline: CardRow.Headline)
    -> (run: CardHeadlines.Run, headline: CardRow.Headline)
  {
    (CardHeadlines.Run(spec: spec, day: day, generation: 0), headline)
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
      CardOpening(kept(steps, .loaded(headline(at: latest))), spec: steps) == .latest(latest))
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
}
