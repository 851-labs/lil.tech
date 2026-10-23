import Dependencies
import HealthDatabase
import HealthUI
import LilSync
import SwiftUI

/// A route no workout shows, in Workout Routes' Other Routes: when it was recorded and where,
/// colored by pace, and how far it went (851-2835).
struct RouteDetailView: View {
  let route: HealthWorkoutRoute
  @Dependency(\.blobCache) private var blobCache
  @State private var locations = RouteState.loading

  var body: some View {
    RouteDetailContent(route: route, locations: locations)
      // Again if sync gives the route other locations.
      .task(id: route.locations) {
        locations = .loading
        locations = await .load(route.locations, from: blobCache)
      }
  }
}

/// What a route's page shows, however it got its locations.
struct RouteDetailContent: View {
  let route: HealthWorkoutRoute
  let locations: RouteState
  /// For its distance's unit, km or mi (851-3176).
  @Dependency(\.locale) private var locale

  var body: some View {
    // A grouped form on its own background, as a workout's page is (851-3001): the route and
    // its figures, then its map.
    Form {
      Section {
        header
        summary
      }
      Section {
        RouteMapRow(route: locations, height: 420, saysWhenEmpty: true)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Route")
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "map")
        .font(.largeTitle)
        .foregroundStyle(.green)
        .frame(width: 64, height: 64)
        .background(.green.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text("Route")
          .font(.title2.bold())
        Text(
          (Date(unixMilliseconds: route.startDate)..<Date(unixMilliseconds: route.endDate))
            .formatted(.interval.month(.abbreviated).day().year().hour().minute())
        )
        .foregroundStyle(.secondary)
        Text(route.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
  }

  /// Its time, and its distance once its locations are here.
  private var summary: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
      ],
      alignment: .leading, spacing: 12
    ) {
      WorkoutFigure(label: "Time", value: WorkoutFormat.duration(route.elapsed), color: .yellow)
      if case .loaded(let loaded) = locations, loaded.hasMap {
        WorkoutFigure(
          label: "Distance",
          value: WorkoutFormat.distance(
            loaded.distance, in: WorkoutFormat.splitUnit(locale: locale)),
          color: .cyan)
      }
    }
    .padding(.vertical, 6)
  }
}

/// A route in Other Routes: how long it took, and when.
struct OtherRouteRow: View {
  let route: HealthWorkoutRoute

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "map")
        .font(.title3)
        .foregroundStyle(.green)
        .frame(width: 36, height: 36)
        .background(.green.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text("Route")
          .font(.headline)
        Text(WorkoutFormat.duration(route.elapsed))
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(.green)
      }
      Spacer()
      Text(Date(unixMilliseconds: route.startDate).formatted(date: .abbreviated, time: .omitted))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}
