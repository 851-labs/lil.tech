#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Workouts (`WorkoutsContent`) and a workout (`WorkoutDetailContent`): the catalog database's
  // workouts, and a made-up route. Synthetic data only.

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

  /// The catalog database's latest workout of `kind` (37, a run), with its heart rates.
  @MainActor
  private func detail(_ route: (HealthWorkout) -> RouteState, kind: Int = 37) -> some View {
    let workout = workouts.first { $0.activityType == kind }!
    let heartRates = try! catalogDatabase.read { db in
      try HealthDatabase.samples(
        of: HealthDatabase.heartRateType,
        in: Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate), db)
    }
    return NavigationStack {
      WorkoutDetailContent(workout: workout, heartRates: heartRates, route: route(workout))
    }
  }
#endif
