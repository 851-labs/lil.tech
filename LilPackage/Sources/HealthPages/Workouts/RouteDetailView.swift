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
  @State private var locations = WorkoutDetailContent.Route.loading

  var body: some View {
    RouteDetailContent(route: route, locations: locations)
      .task(id: route.id) {
        locations = await loadLocations()
      }
  }

  private func loadLocations() async -> WorkoutDetailContent.Route {
    guard let sha256 = route.locations else { return .none }
    do {
      return .loaded(HealthDatabase.routeLocations(try await blobCache.data(for: sha256)))
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}

/// What a route's page shows, however it got its locations.
struct RouteDetailContent: View {
  let route: HealthWorkoutRoute
  let locations: WorkoutDetailContent.Route
  /// Worked out once, not on every render.
  private let distance: Double?

  init(route: HealthWorkoutRoute, locations: WorkoutDetailContent.Route) {
    self.route = route
    self.locations = locations
    if case .loaded(let points) = locations, points.count > 1 {
      distance = HealthDatabase.routeDistance(points)
    } else {
      distance = nil
    }
  }

  private var elapsed: TimeInterval { Double(route.endDate - route.startDate) / 1000 }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        summary
        map
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
      figure("Time", WorkoutFormat.duration(elapsed), .yellow)
      if let distance {
        figure(
          "Distance", (distance / 1000).formatted(.number.precision(.fractionLength(2))) + " km",
          .cyan)
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

  private var map: some View {
    Group {
      switch locations {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 360)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load the Route", systemImage: "map", description: Text(reason))
      case .loaded(let points) where points.count > 1:
        RouteMap(locations: points)
          .frame(height: 420)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      case .none, .loaded:
        ContentUnavailableView(
          "No Locations", systemImage: "map",
          description: Text("This route has no locations to show."))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(12)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
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
        Text(WorkoutFormat.duration(Double(route.endDate - route.startDate) / 1000))
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
