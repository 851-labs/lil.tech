import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health activity`'s text (851-4158): each day's rings, leaving out those without a goal,
// and whether they were paused. Synthetic data only.
@Suite struct ActivityRingsTextTests {
  @Test func listsEachDaysRings() {
    let result = HealthActivityRingsResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00",
      days: [
        HealthActivityDay(
          date: "2026-10-15", move: HealthActivityRing(value: 42, goal: 30, unit: "min"),
          exercise: HealthActivityRing(value: 18, goal: 30, unit: "min"),
          stand: HealthActivityRing(value: 9, goal: 12, unit: "hr"), paused: false),
        HealthActivityDay(
          date: "2026-10-16", move: HealthActivityRing(value: 210.5, goal: 400, unit: "kcal"),
          exercise: nil, stand: nil, paused: false),
        HealthActivityDay(
          date: "2026-10-17", move: HealthActivityRing(value: 95, goal: 500, unit: "kcal"),
          exercise: HealthActivityRing(value: 0, goal: 30, unit: "min"),
          stand: HealthActivityRing(value: 4, goal: 12, unit: "hr"), paused: true),
      ])
    #expect(
      result.text == """
        Activity rings, W: 2026-10-14 to 2026-10-20 (UTC)

          2026-10-15   Move 42/30 min · Exercise 18/30 min · Stand 9/12 hr
          2026-10-16   Move 210.5/400 kcal
          2026-10-17   Move 95/500 kcal · Exercise 0/30 min · Stand 4/12 hr · paused

        """)
  }

  @Test func saysWhenThereAreNone() {
    let result = HealthActivityRingsResult(
      timeZone: "UTC", range: "D", start: "2026-10-18T00:00:00+00:00",
      end: "2026-10-19T00:00:00+00:00", days: [])
    #expect(
      result.text == """
        Activity rings, D: 2026-10-18 to 2026-10-18 (UTC)

        No Activity rings recorded.

        """)
  }
}
