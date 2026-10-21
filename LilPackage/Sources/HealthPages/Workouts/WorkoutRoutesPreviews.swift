import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// Workout Routes (851-2835). In their own file: previewing a file with a `List` of `ForEach` rows
// trips an assertion in SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: the runs and
// walks of `makePreviewHealthDatabase()`, and made-up routes.

/// The preview database's runs and walks, as if each had a route.
@MainActor
private func previewWorkoutsWithRoutes() -> [HealthWorkout] {
  let workouts =
    (try? makePreviewHealthDatabase().read { db in try HealthDatabase.workouts(limit: 50, db) })
    ?? []
  return workouts.filter { WorkoutActivity.hasPace($0.activityType) }
}

/// A made-up route `daysAgo` days ago at `hour`, lasting `minutes`, that no workout shows.
private func previewOtherRoute(_ id: String, daysAgo: Int, hour: Double, minutes: Double)
  -> HealthWorkoutRoute
{
  let start = Calendar.current.startOfDay(for: .now)
    .addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
  return HealthWorkoutRoute(
    id: id, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, workout: nil,
    locationCount: Int(minutes * 12), locations: "preview", sourceName: "iPhone",
    sourceBundleID: "com.example.tracker")
}

private let previewOtherRoutes = [
  previewOtherRoute("walk-to-work", daysAgo: 1, hour: 8.5, minutes: 22),
  previewOtherRoute("evening-loop", daysAgo: 6, hour: 19.25, minutes: 47),
]

@MainActor
private func list(_ state: WorkoutsContent.State) -> some View {
  NavigationStack {
    WorkoutsContent(state: state, onlyWithRoutes: true)
  }
  .previewFrame(width: 620, height: 640)
}

#Preview("Workout routes") {
  list(.loaded(previewWorkoutsWithRoutes(), otherRoutes: previewOtherRoutes))
}

#Preview("Workout routes, no other routes") {
  list(.loaded(previewWorkoutsWithRoutes()))
}

#Preview("Only other routes") {
  list(.loaded([], otherRoutes: previewOtherRoutes))
}

#Preview("No workout routes") {
  list(.loaded([]))
}

#Preview("Workout routes loading") {
  list(.loading)
}

#Preview("Workout routes failed") {
  list(.failed("The database couldn't be read."))
}

/// A made-up 2.4 km walk along the Embarcadero, northwest from the Ferry Building, slowing
/// toward the end.
private func previewLocations(of route: HealthWorkoutRoute) -> [RouteLocation] {
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
private func route(_ locations: (HealthWorkoutRoute) -> WorkoutDetailContent.Route)
  -> some View
{
  let route = previewOtherRoutes[0]
  return NavigationStack {
    RouteDetailContent(route: route, locations: locations(route))
  }
  .previewFrame(width: 760, height: 760)
}

#Preview("Other route") {
  route { .loaded(previewLocations(of: $0)) }
}

#Preview("Other route loading") {
  route { _ in .loading }
}

#Preview("Other route failed") {
  route { _ in .failed("The route couldn't be downloaded.") }
}

#Preview("Other route without locations") {
  route { _ in .none }
}
