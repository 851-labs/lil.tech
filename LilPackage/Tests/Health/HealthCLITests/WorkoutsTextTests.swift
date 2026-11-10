import Foundation
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

  @Test
  func aWorkoutListsItsStatisticsPausesLapsAndWeather() throws {
    let json = """
      {"timeZone": "UTC", "workout": {"id": "a", "activityType": 46, "activity": "Swimming",
        "name": null, "start": "2026-09-04T06:30:00+00:00", "end": "2026-09-04T07:00:00+00:00",
        "duration": 1780, "activeEnergy": 210, "distance": 114.3, "averageHeartRate": 131.5,
        "elevationAscended": null, "indoor": true, "swimmingLocation": "pool", "hasRoute": false,
        "source": "Synthetic Watch", "elevationDescended": null, "averageSpeed": null,
        "maximumSpeed": null, "averageMETs": 7.5, "lapLength": 22.86, "swolf": 45,
        "weatherCondition": "clear", "weatherTemperature": 27, "weatherHumidity": 45.5,
        "statistics": [
          {"type": "HKQuantityTypeIdentifierHeartRate", "name": "Heart Rate", "unit": "count/min",
           "sum": null, "average": 131.5, "minimum": 104, "maximum": 152, "mostRecent": 140},
          {"type": "HKQuantityTypeIdentifierSwimmingStrokeCount", "name": "Swimming Strokes",
           "unit": "count", "sum": 96, "average": null, "minimum": null, "maximum": null,
           "mostRecent": null}],
        "pauseCount": 1,
        "pauses": [{"start": "2026-09-04T06:59:40+00:00", "end": "2026-09-04T07:00:00+00:00",
          "duration": 20}],
        "lapCount": 3,
        "laps": [
          {"start": "2026-09-04T06:30:00+00:00", "end": "2026-09-04T06:30:30+00:00",
           "duration": 30, "strokeStyle": "freestyle", "swolf": 41, "lapLength": 22.86,
           "averageSpeed": null, "maximumSpeed": null},
          {"start": "2026-09-04T06:30:30+00:00", "end": "2026-09-04T06:31:02+00:00",
           "duration": 32, "strokeStyle": null, "swolf": null, "lapLength": null,
           "averageSpeed": null, "maximumSpeed": null}],
        "segmentCount": 0, "segments": [], "activities": []}}
      """
    let result = try JSONDecoder().decode(HealthWorkoutResult.self, from: Data(json.utf8))
    #expect(
      result.text == """
        2026-09-04 06:30   Swimming   indoor, pool   29m (UTC)
        From Synthetic Watch

          Heart Rate         avg. 131.5 count/min · min. 104 count/min · max. 152 count/min
          Swimming Strokes   96

          Avg. METs   7.5
          Pool        22.86 m
          SWOLF       45
          Weather     clear, 27 °C, 45.5% humidity

        Pauses: 1
          2026-09-04 06:59   20s

        Laps: 3
          2026-09-04 06:30   30s   freestyle   SWOLF 41
          2026-09-04 06:30   32s
          … and 1 more

        """)
  }
}
