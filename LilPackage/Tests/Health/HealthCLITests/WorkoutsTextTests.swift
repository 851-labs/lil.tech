import Testing

@testable import HealthCLI
@testable import HealthTools

// Synthetic data only (AGENTS.md).
@Suite struct WorkoutsTextTests {
  @Test
  func workoutsSayWhereTheyWereAndTheirActivities() {
    let result = HealthWorkoutsResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3, duration: 10_800,
      workouts: [
        HealthWorkoutItem(
          id: "a", activityType: 37, activity: "Running", name: "Synthetic Intervals",
          start: "2026-10-20T07:00:00+00:00", end: "2026-10-20T07:30:00+00:00", duration: 1800,
          indoor: false, hasRoute: true, source: "Synthetic Watch", activities: []),
        HealthWorkoutItem(
          id: "b", activityType: 37, activity: "Running", start: "2026-10-19T07:00:00+00:00",
          end: "2026-10-19T07:30:00+00:00", duration: 1800, indoor: true, hasRoute: false,
          source: "Synthetic Watch", activities: []),
        HealthWorkoutItem(
          id: "c", activityType: 82, activity: "Multisport", start: "2026-10-18T07:00:00+00:00",
          end: "2026-10-18T09:00:00+00:00", duration: 7200, hasRoute: false,
          source: "Synthetic Watch",
          activities: [
            HealthWorkoutActivityItem(
              activityType: 46, activity: "Swimming", start: "2026-10-18T07:00:00+00:00",
              end: "2026-10-18T07:30:00+00:00", duration: 1800, indoor: false,
              swimmingLocation: "openWater"),
            HealthWorkoutActivityItem(
              activityType: 83, activity: "Transition", start: "2026-10-18T07:30:00+00:00",
              end: "2026-10-18T07:35:00+00:00", duration: 300),
          ]),
      ])
    #expect(
      result.text == """
        Workouts, W: 2026-10-14 to 2026-10-20 (UTC)
        3 workouts, 3h 00m

          2026-10-20 07:00   Running “Synthetic Intervals”   outdoor, GPS route   30m
          2026-10-19 07:00   Running   indoor   30m
          2026-10-18 07:00   Multisport   2h 00m
              Swimming   outdoor, open water   30m
              Transition   5m

        """)
  }
}
