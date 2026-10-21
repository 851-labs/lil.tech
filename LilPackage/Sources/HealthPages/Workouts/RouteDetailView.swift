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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        summary
        RouteMapCard(route: locations, height: 420, saysWhenEmpty: true)
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.pageBackground)
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
  }

  /// Its time, and its distance once its locations are here.
  private var summary: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      figure("Time", WorkoutFormat.duration(route.elapsed), .yellow)
      if case .loaded(let loaded) = locations, loaded.hasMap {
        figure(
          "Distance",
          (loaded.distance / 1000).formatted(.number.precision(.fractionLength(2))) + " km", .cyan)
      }
    }
    .padding(16)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  private func figure(_ label: String, _ value: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
