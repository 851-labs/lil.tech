import HealthDatabase
import LilSync
import SwiftUI

/// A route's locations, as a page gets them: downloaded when it's shown.
enum RouteState {
  case loading
  /// No route, or one without locations.
  case none
  case loaded(LoadedRoute)
  case failed(String)

  /// The locations in the route blob `sha256`, from the cache or downloaded.
  static func load(_ sha256: String?, from blobCache: BlobCache) async -> Self {
    guard let sha256 else { return .none }
    do {
      return .loaded(
        LoadedRoute(HealthDatabase.routeLocations(try await blobCache.data(for: sha256))))
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}

/// A route's locations, with what pages show of them worked out once, when they load.
struct LoadedRoute {
  let locations: [RouteLocation]
  /// How far it went, in meters.
  let distance: Double

  init(_ locations: [RouteLocation]) {
    self.locations = locations
    distance = HealthDatabase.routeDistance(locations)
  }

  /// Whether there's a line to draw.
  var hasMap: Bool { locations.count > 1 }
}

/// A route's map in a form row, colored by pace, or how its loading is going.
struct RouteMapRow: View {
  let route: RouteState
  var height: CGFloat = 300
  /// Whether a route without locations says so, rather than showing nothing.
  var saysWhenEmpty = false

  /// Whether there's anything to show for `route`, so a page can leave out its section.
  static func shows(_ route: RouteState, saysWhenEmpty: Bool = false) -> Bool {
    switch route {
    case .loading, .failed: true
    case .loaded(let loaded) where loaded.hasMap: true
    case .none, .loaded: saysWhenEmpty
    }
  }

  var body: some View {
    switch route {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: height * 0.8)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load the Route", systemImage: "map", description: Text(reason)
      )
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let loaded) where loaded.hasMap:
      RouteMap(locations: loaded.locations)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 6)
    case .none, .loaded:
      if saysWhenEmpty {
        ContentUnavailableView(
          "No Locations", systemImage: "map",
          description: Text("This route has no locations to show.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
