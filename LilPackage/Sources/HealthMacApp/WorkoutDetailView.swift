import Charts
import Dependencies
import HealthCatalog
import HealthDatabase
import LilSync
import MapKit
import SQLiteData
import SwiftUI

/// A workout, as in Health: its summary figures, heart rate over the workout, the route colored
/// by pace with its kilometer splits, and its segments.
struct WorkoutDetailView: View {
  let workout: HealthWorkout
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.blobCache) private var blobCache
  @State private var heartRates: [HealthSample] = []
  @State private var route = WorkoutDetailContent.Route.loading

  var body: some View {
    WorkoutDetailContent(workout: workout, heartRates: heartRates, route: route)
      .task(id: workout.id) {
        let workout = workout
        // Both at once: the route may have to be downloaded.
        async let samples = try? database.read { db in
          try HealthDatabase.samples(
            of: WorkoutFormat.heartRate,
            in: Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate),
            db)
        }
        async let loaded = loadRoute(workout)
        heartRates = Self.mainSource(await samples ?? [])
        route = await loaded
      }
  }

  /// The samples of the source that recorded the most during the workout (usually the Watch),
  /// so a second device's readings don't zig-zag through the chart.
  static func mainSource(_ samples: [HealthSample]) -> [HealthSample] {
    let counts = Dictionary(grouping: samples, by: \.sourceBundleID).mapValues(\.count)
    guard let source = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
    else { return [] }
    return samples.filter { $0.sourceBundleID == source }
  }

  private func loadRoute(_ workout: HealthWorkout) async -> WorkoutDetailContent.Route {
    do {
      guard
        let sha256 = try await database.read({ db in try HealthDatabase.route(of: workout, db) })?
          .locations
      else { return .none }
      return .loaded(HealthDatabase.routeLocations(try await blobCache.data(for: sha256)))
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}

/// What a workout's detail shows, however it got it.
struct WorkoutDetailContent: View {
  enum Route {
    case loading
    case none
    case loaded([RouteLocation])
    case failed(String)
  }

  let workout: HealthWorkout
  let heartRates: [HealthSample]
  let route: Route
  /// Decoded and worked out once, not on every render.
  private let statistics: [String: WorkoutStatistic]
  private let splits: [RouteSplit]

  init(workout: HealthWorkout, heartRates: [HealthSample], route: Route) {
    self.workout = workout
    self.heartRates = heartRates
    self.route = route
    statistics = workout.decodedStatistics
    if case .loaded(let locations) = route {
      splits = HealthDatabase.splits(locations, pauses: workout.pauses)
    } else {
      splits = []
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        summary
        if !heartRates.isEmpty { heartRateCard }
        routeSection
        segments
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.groupedBackground)
    .navigationTitle(WorkoutActivity.name(workout.activityType))
  }

  // MARK: Header and summary

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: WorkoutActivity.symbol(workout.activityType))
        .font(.largeTitle)
        .foregroundStyle(.green)
        .frame(width: 64, height: 64)
        .background(.green.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(WorkoutActivity.name(workout.activityType))
          .font(.title2.bold())
        Text(
          (Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate))
            .formatted(.interval.month(.abbreviated).day().hour().minute())
        )
        .foregroundStyle(.secondary)
        Text(workout.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The figures Health shows for a workout, those it recorded.
  private var summary: some View {
    let figures = summaryFigures
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      ForEach(figures, id: \.label) { figure in
        VStack(alignment: .leading, spacing: 2) {
          Text(figure.label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(figure.value)
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(figure.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  private var summaryFigures: [(label: String, value: String, color: Color)] {
    var figures: [(String, String, Color)] = [
      ("Workout Time", WorkoutFormat.duration(workout.duration), .yellow),
      ("Elapsed Time", WorkoutFormat.duration(workout.elapsed), .yellow),
    ]
    if let meters = WorkoutFormat.distance(statistics), meters > 0 {
      figures.append(
        (
          "Distance", (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km",
          .cyan
        ))
      if WorkoutActivity.hasPace(workout.activityType), workout.duration > 0 {
        figures.append(
          ("Avg. Pace", WorkoutFormat.pace(workout.duration / meters * 1000), .cyan))
      }
    }
    let active = statistics[WorkoutFormat.activeEnergy]?.sum
    if let active {
      figures.append(("Active Calories", "\(Int(active.rounded())) kcal", .pink))
    }
    if let active, let basal = statistics[WorkoutFormat.basalEnergy]?.sum {
      figures.append(("Total Calories", "\(Int((active + basal).rounded())) kcal", .pink))
    }
    if let average = statistics[WorkoutFormat.heartRate]?.average {
      figures.append(("Avg. Heart Rate", "\(Int(average.rounded())) BPM", .red))
    }
    return figures.map { (label: $0.0, value: $0.1, color: $0.2) }
  }

  // MARK: Heart rate

  private var heartRateCard: some View {
    let values = heartRates.compactMap(\.value)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Heart Rate")
          .font(.headline)
        Spacer()
        if let low = values.min(), let high = values.max() {
          Text("\(Int(low.rounded()))–\(Int(high.rounded())) BPM")
            .foregroundStyle(.secondary)
        }
      }
      Chart(heartRates) { sample in
        if let value = sample.value {
          LineMark(
            x: .value("Time", Date(unixMilliseconds: sample.startDate)),
            y: .value("BPM", value)
          )
          .foregroundStyle(.red)
          .interpolationMethod(.catmullRom)
        }
      }
      .chartYScale(domain: .automatic(includesZero: false))
      .chartXAxis {
        AxisMarks { _ in
          AxisGridLine()
          AxisValueLabel(format: .dateTime.hour().minute())
        }
      }
      .frame(height: 160)
    }
    .padding(16)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: Route and splits

  @ViewBuilder private var routeSection: some View {
    switch route {
    case .none:
      EmptyView()
    case .loading:
      card {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 240)
      }
    case .failed(let reason):
      card {
        ContentUnavailableView(
          "Couldn't Load the Route", systemImage: "map", description: Text(reason))
      }
    case .loaded(let locations) where locations.count < 2:
      EmptyView()
    case .loaded(let locations):
      card {
        RouteMap(locations: locations)
          .frame(height: 300)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      splitsTable
    }
  }

  private var splitsTable: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Splits")
        .font(.title3.bold())
      VStack(spacing: 0) {
        HStack {
          Text("KM").frame(width: 50, alignment: .leading)
          Text("Time").frame(maxWidth: .infinity, alignment: .leading)
          Text("Pace").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        ForEach(Array(splits.enumerated()), id: \.offset) { index, split in
          Divider().padding(.leading, 14)
          HStack {
            Text(
              split.distance < 990
                ? (Double(index) + split.distance / 1000).formatted(
                  .number.precision(.fractionLength(2)))
                : "\(index + 1)"
            )
            .frame(width: 50, alignment: .leading)
            Text(WorkoutFormat.duration(split.duration))
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(WorkoutFormat.pace(split.pace))
              .foregroundStyle(.cyan)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .monospacedDigit()
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        }
      }
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: Segments

  @ViewBuilder private var segments: some View {
    let segments = workout.decodedEvents.filter { $0.type == WorkoutEvent.segment }
    if !segments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Segments")
          .font(.title3.bold())
        VStack(spacing: 0) {
          ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
            if index > 0 { Divider().padding(.leading, 14) }
            HStack {
              Text("Segment \(index + 1)")
              Spacer()
              Text(WorkoutFormat.duration(segment.duration))
                .monospacedDigit()
                .foregroundStyle(.yellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
          }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    content()
      .frame(maxWidth: .infinity)
      .padding(12)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }
}

/// A route on a map, colored by pace: green where it was fastest, through yellow, to red where
/// it was slowest, relative to the route itself.
struct RouteMap: View {
  private let pieces: [(coordinates: [CLLocationCoordinate2D], color: Color)]
  private let bounds: MKMapRect

  init(locations: [RouteLocation]) {
    pieces = Self.pieces(locations)
    bounds = Self.bounds(locations)
  }

  var body: some View {
    Map(initialPosition: .rect(bounds)) {
      ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
        MapPolyline(coordinates: piece.coordinates)
          .stroke(piece.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
      }
    }
    .mapStyle(.standard(pointsOfInterest: .excludingAll))
  }

  /// The route's bounding box, with a margin.
  static func bounds(_ locations: [RouteLocation]) -> MKMapRect {
    let points = locations.map {
      MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
    }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return .world }
    let rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    return rect.insetBy(dx: -rect.width * 0.15 - 200, dy: -rect.height * 0.15 - 200)
  }

  /// The route in short pieces, each colored by its speed's place between the route's slowest
  /// and fastest (the 10th and 90th percentiles, so a GPS jump doesn't set the scale).
  static func pieces(_ locations: [RouteLocation]) -> [(
    coordinates: [CLLocationCoordinate2D], color: Color
  )] {
    let speeds = locations.map(\.speed).filter { $0 >= 0 }.sorted()
    guard speeds.count > 1 else {
      return [
        (
          locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
          .green
        )
      ]
    }
    let slow = speeds[speeds.count / 10]
    let fast = speeds[speeds.count * 9 / 10]
    let pieceLength = max(locations.count / 60, 2)
    return stride(from: 0, to: locations.count - 1, by: pieceLength - 1).map { start in
      let piece = locations[start...min(start + pieceLength - 1, locations.count - 1)]
      // Over the speeds it knows: unknown ones (negative) aren't slow.
      let known = piece.map(\.speed).filter { $0 >= 0 }
      let share: Double
      if known.isEmpty || fast <= slow {
        share = 1
      } else {
        let speed = known.reduce(0, +) / Double(known.count)
        share = min(max((speed - slow) / (fast - slow), 0), 1)
      }
      return (
        piece.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
        // Red (slow) through yellow to green (fast).
        Color(hue: share * 0.33, saturation: 0.9, brightness: 0.9)
      )
    }
  }
}
