import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: `makePreviewHealthDatabase()`, and a
// made-up route.

@MainActor
private func previewWorkouts() -> [HealthWorkout] {
  (try? makePreviewHealthDatabase().read { db in try HealthDatabase.workouts(limit: 50, db) })
    ?? []
}

@MainActor
private func list(_ state: WorkoutsContent.State) -> some View {
  NavigationStack {
    WorkoutsContent(state: state)
  }
  .previewFrame(width: 620, height: 640)
}

#Preview("Workouts") {
  list(.loaded(previewWorkouts()))
}

#Preview("No workouts") {
  list(.loaded([]))
}

#Preview("Workouts loading") {
  list(.loading)
}

#Preview("Workouts failed") {
  list(.failed("The database couldn't be read."))
}

/// A made-up 5 km loop in Golden Gate Park, faster on the way out than back.
private func previewRoute(of workout: HealthWorkout) -> [RouteLocation] {
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

@MainActor
private func detail(_ route: (HealthWorkout) -> RouteState, kind: Int = 37)
  -> some View
{
  // One database for both: building it is the slow part.
  let (workout, heartRates) = try! makePreviewHealthDatabase().read { db in
    let workout = try HealthDatabase.workouts(limit: 50, db).first { $0.activityType == kind }!
    let heartRates = try HealthDatabase.samples(
      of: "HKQuantityTypeIdentifierHeartRate",
      in: Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate), db)
    return (workout, heartRates)
  }
  return NavigationStack {
    WorkoutDetailContent(workout: workout, heartRates: heartRates, route: route(workout))
  }
  .previewFrame(width: 760, height: 1300)
}

#Preview("Run with route") {
  detail { .loaded(LoadedRoute(previewRoute(of: $0))) }
}

#Preview("Strength, no route") {
  detail({ _ in .none }, kind: 50)
}

#Preview("Route loading") {
  detail { _ in .loading }
}

#Preview("Route failed") {
  detail { _ in .failed("The route couldn't be downloaded.") }
}
