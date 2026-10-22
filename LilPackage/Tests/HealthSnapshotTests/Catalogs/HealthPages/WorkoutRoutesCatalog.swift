#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Workout Routes (`WorkoutsContent`, only with routes, 851-2835) and a route no workout shows
  // (`RouteDetailContent`): the catalog database's runs and walks, and made-up routes. Synthetic
  // data only.

  extension MacSnapshotTests {
    @Test(arguments: workoutRoutesCatalog.selectedStates)
    func workoutRoutes(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let workoutRoutesCatalog = StateCatalog(
    "Workout Routes", width: 620, minHeight: 640,
    states: [
      // Tall enough for the whole list: a `List` doesn't grow to its content.
      CatalogState("Workout routes", minHeight: 800) {
        list(.loaded(workoutsWithRoutes, otherRoutes: otherRoutes))
      },
      CatalogState("Workout routes, no other routes", minHeight: 700) {
        list(.loaded(workoutsWithRoutes))
      },
      CatalogState("Only other routes") { list(.loaded([], otherRoutes: otherRoutes)) },
      CatalogState("No workout routes") { list(.loaded([])) },
      CatalogState("Workout routes loading") { list(.loading) },
      CatalogState("Workout routes failed") { list(.failed("The database couldn't be read.")) },
      // A route.
      // The route without the map: MapKit doesn't draw offscreen (`drawsRouteMaps`).
      CatalogState("Other route", width: 760) {
        route { .loaded(LoadedRoute(locations(of: $0))) }
          .environment(\.drawsRouteMaps, false)
      },
      CatalogState("Other route loading", width: 760) { route { _ in .loading } },
      CatalogState("Other route failed", width: 760) {
        route { _ in .failed("The route couldn't be downloaded.") }
      },
      CatalogState("Other route without locations", width: 760) {
        route { _ in .none }
      },
    ])

  /// The catalog database's runs and walks, as if each had a route. Read once.
  private let workoutsWithRoutes = try! catalogDatabase.read { db in
    try HealthDatabase.workouts(limit: 50, db)
  }
  .filter { WorkoutActivity.hasPace($0.activityType) }

  /// A made-up route `daysAgo` days before `previewNow` at `hour`, lasting `minutes`, that no
  /// workout shows.
  private func otherRoute(_ id: String, daysAgo: Int, hour: Double, minutes: Double)
    -> HealthWorkoutRoute
  {
    let start = previewCalendar.startOfDay(for: previewNow)
      .addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    return HealthWorkoutRoute(
      id: id, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, workout: nil,
      locationCount: Int(minutes * 12), locations: "preview", sourceName: "iPhone",
      sourceBundleID: "com.example.tracker")
  }

  private let otherRoutes = [
    otherRoute("walk-to-work", daysAgo: 1, hour: 8.5, minutes: 22),
    otherRoute("evening-loop", daysAgo: 6, hour: 19.25, minutes: 47),
  ]

  @MainActor
  private func list(_ state: WorkoutsContent.State) -> some View {
    NavigationStack {
      WorkoutsContent(state: state, onlyWithRoutes: true)
    }
  }

  /// A made-up 2.4 km walk along the Embarcadero, northwest from the Ferry Building, slowing
  /// toward the end.
  private func locations(of route: HealthWorkoutRoute) -> [RouteLocation] {
    let start = Date(unixMilliseconds: route.startDate)
    let count = 264
    return (0..<count).map { index in
      let progress = Double(index) / Double(count - 1)
      return RouteLocation(
        time: start.addingTimeInterval(Double(index) * 5),
        latitude: 37.7955 + 0.016 * progress + 0.0015 * sin(progress * .pi),
        longitude: -122.3937 - 0.018 * progress, altitude: 4,
        speed: 1.9 - 0.5 * progress)
    }
  }

  @MainActor
  private func route(_ locations: (HealthWorkoutRoute) -> RouteState) -> some View {
    let route = otherRoutes[0]
    return NavigationStack {
      RouteDetailContent(route: route, locations: locations(route))
    }
  }
#endif
