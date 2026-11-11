#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Workouts (`WorkoutsContent`) and a workout (`WorkoutDetailContent`): the catalog database's
  // workouts, a made-up route, effort scores and a multisport workout's legs. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: workoutsCatalog.selectedStates)
    func workouts(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let workoutsCatalog = StateCatalog(
    "Workouts", width: 620, minHeight: 640,
    states: [
      CatalogState("Workouts") { list(.loaded(workouts)) },
      CatalogState("No workouts") { list(.loaded([])) },
      CatalogState("Workouts loading") { list(.loading) },
      CatalogState("Workouts failed") { list(.failed("The database couldn't be read.")) },
      // In the locale's units (851-3176): miles.
      CatalogState("Workouts, US", locale: us) { list(.loaded(workouts)) },
      // A workout.
      // The route without the map: MapKit doesn't draw offscreen (`drawsRouteMaps`).
      CatalogState("Run with route", width: 760) {
        detail { .loaded(LoadedRoute(route(of: $0))) }
          .environment(\.drawsRouteMaps, false)
      },
      // Miles, pace per mile, and splits recomputed per mile.
      CatalogState("Run with route, US", width: 760, locale: us) {
        detail { .loaded(LoadedRoute(route(of: $0))) }
          .environment(\.drawsRouteMaps, false)
      },
      CatalogState("Strength, no route", width: 760) {
        detail({ _ in .none }, kind: 50)
      },
      // Recorded in Tokyo (851-4179): a Time Zone row, with its start on Tokyo's clock.
      CatalogState("Strength, recorded in Tokyo", width: 760) {
        detail({ _ in .none }, kind: 50, timeZone: "Asia/Tokyo")
      },
      // Its effort score (851-4186): one the person rated, and Apple Watch's estimate.
      CatalogState("Strength, rated effort", width: 760) {
        detail({ _ in .none }, kind: 50, effort: { effortScore(7, after: $0) })
      },
      CatalogState("Run, estimated effort", width: 760) {
        detail({ _ in .none }, effort: { effortScore(4.4, after: $0, estimated: true) })
      },
      // A swim, a ride and a run, each with an effort score of its own, and one for the whole.
      CatalogState("Multisport, legs with effort", width: 760) { multisport() },
      // Its heart rate guessed from its time (851-4186): its links haven't synced, or there were
      // too many to.
      CatalogState("Run, links not synced", width: 760) {
        detail({ _ in .none }, heartRates: .notSynced)
      },
      CatalogState("Run, too many samples to link", width: 760) {
        detail({ _ in .none }, heartRates: .tooMany)
      },
      CatalogState("Route loading", width: 760) { detail { _ in .loading } },
      CatalogState("Route failed", width: 760) {
        detail { _ in .failed("The route couldn't be downloaded.") }
      },
    ],
    // A route's map keeps its place and height, loading or not (851-3091).
    sameLayout: [
      ["Run with route", "Route loading", "Route failed"]
    ])

  private let us = Locale(identifier: "en_US")

  /// The catalog database's latest workouts, read once.
  private let workouts = try! catalogDatabase.read { db in
    try HealthDatabase.workouts(limit: 50, db)
  }

  @MainActor
  private func list(_ state: WorkoutsContent.State) -> some View {
    NavigationStack {
      WorkoutsContent(state: state)
    }
  }

  /// A made-up 5 km loop in Golden Gate Park, faster on the way out than back.
  private func route(of workout: HealthWorkout) -> [RouteLocation] {
    let start = Date(unixMilliseconds: workout.startDate)
    let center = (latitude: 37.7694, longitude: -122.4862)
    return (0..<300).map { index in
      let angle = Double(index) / 300 * 2 * .pi
      let speed = 3.6 + 0.6 * cos(angle)
      return RouteLocation(
        time: start.addingTimeInterval(Double(index) * 5),
        latitude: center.latitude + 0.004 * sin(angle),
        longitude: center.longitude + 0.012 * cos(angle), altitude: 20, speed: speed)
    }
  }

  /// The catalog database's latest workout of `kind` (37, a run), with its heart rates (found as
  /// `heartRates` says), recorded in the zone named `timeZone` (`HKTimeZone`) if given, and with
  /// the effort score `effort` gives it, if any.
  @MainActor
  private func detail(
    _ route: (HealthWorkout) -> RouteState, kind: Int = 37, timeZone: String? = nil,
    heartRates origin: WorkoutHeartRates.Origin = .linked,
    effort: (HealthWorkout) -> HealthSample? = { _ in nil }
  ) -> some View {
    var workout = workouts.first { $0.activityType == kind }!
    if let timeZone {
      workout.metadata = metadataRecorded(in: timeZone, workout.metadata)
    }
    return NavigationStack {
      WorkoutDetailContent(
        workout: workout,
        heartRates: WorkoutHeartRates(samples: heartRates(during: workout), origin: origin),
        effort: effort(workout).map { WorkoutEffort(score: $0) }, route: route(workout))
    }
  }

  /// The catalog database's heart rates during `workout`: what its app would have added to it.
  private func heartRates(during workout: HealthWorkout) -> [HealthSample] {
    try! catalogDatabase.read { db in
      try HealthDatabase.samples(
        of: HealthDatabase.heartRateType,
        in: Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate), db)
    }
  }

  /// A made-up effort score of `value`, rated (or estimated) `minutes` after `workout` ended, as
  /// scores often are.
  private func effortScore(
    _ value: Double, after workout: HealthWorkout, minutes: Int = 12, estimated: Bool = false,
    id: String = "e1f0a7c3-0000-4000-8000-000000000001"
  ) -> HealthSample {
    let at = workout.endDate + minutes * 60_000
    return HealthSample(
      id: id,
      type: estimated
        ? HealthDatabase.estimatedWorkoutEffortScoreType : HealthDatabase.workoutEffortScoreType,
      startDate: at, endDate: at, value: value, unit: "appleEffortScore",
      sourceName: estimated ? "Apple Watch" : "Fitness",
      sourceBundleID: estimated ? "com.apple.health" : "com.apple.Fitness")
  }

  /// The catalog database's latest run, made a multisport workout: a swim, a ride and a run in
  /// turn, each with its own effort score, and one for the whole.
  @MainActor
  private func multisport() -> some View {
    var workout = workouts.first { $0.activityType == 37 }!
    workout.activityType = 82
    let (start, end) = (workout.startDate, workout.endDate)
    let third = (end - start) / 3
    let legs = [(46, "a1"), (13, "a2"), (37, "a3")].enumerated().map { index, leg in
      (
        id: "5b2d9e10-0000-4000-8000-0000000000\(leg.1)", activityType: leg.0,
        start: start + index * third, end: start + (index + 1) * third
      )
    }
    workout.activities =
      "["
      + legs.map {
        #"{"id":"\#($0.id)","activityType":\#($0.activityType),"startDate":\#($0.start),"#
          + #""endDate":\#($0.end),"duration":\#(Double($0.end - $0.start) / 1000),"#
          + #""locationType":3,"swimmingLocationType":0,"metadata":null,"statistics":{}}"#
      }.joined(separator: ",") + "]"
    let scores = [(6.0, "a1"), (8, "a2"), (9, "a3")]
    let effort = WorkoutEffort(
      score: effortScore(8, after: workout),
      legs: Dictionary(
        uniqueKeysWithValues: zip(legs, scores).map { leg, score in
          (
            leg.id,
            effortScore(
              score.0, after: workout, minutes: 13,
              id: "e1f0a7c3-0000-4000-8000-0000000000\(score.1)")
          )
        }))
    return NavigationStack {
      WorkoutDetailContent(
        workout: workout,
        heartRates: WorkoutHeartRates(samples: heartRates(during: workout), origin: .linked),
        effort: effort, route: .none)
    }
  }
#endif
