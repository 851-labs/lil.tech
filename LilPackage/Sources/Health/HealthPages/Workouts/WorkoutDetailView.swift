import Charts
import Dependencies
import HealthCatalog
import HealthDatabase
import HealthUI
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
  /// `.none` until the workout's route is known to exist: a workout without one never shows a
  /// placeholder for it (851-3091).
  @State private var route = RouteState.none

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
        async let row = routeRow(workout)
        // Both from the local database, set together, so the heart rate and the route's
        // placeholder arrive at once, and only then the route, which may have to be downloaded.
        let found = await row
        heartRates = Self.mainSource(await samples ?? [])
        switch found {
        case .failure(let error):
          route = .failed(error.localizedDescription)
        case .success(nil):
          route = .none
        case .success(let route?):
          self.route = .loading
          self.route = await .load(route.locations, from: blobCache)
        }
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

  /// The workout's route, if it has one.
  private func routeRow(_ workout: HealthWorkout) async -> Result<HealthWorkoutRoute?, any Error> {
    do {
      return .success(
        try await database.read { db in try HealthDatabase.route(of: workout, db) })
    } catch {
      return .failure(error)
    }
  }
}

/// What a workout's detail shows, however it got it.
struct WorkoutDetailContent: View {
  let workout: HealthWorkout
  let heartRates: [HealthSample]
  let route: RouteState
  /// Decoded and worked out once, not on every render.
  private let statistics: [String: WorkoutStatistic]
  private let splits: [RouteSplit]

  init(workout: HealthWorkout, heartRates: [HealthSample], route: RouteState) {
    self.workout = workout
    self.heartRates = heartRates
    self.route = route
    statistics = workout.decodedStatistics
    if case .loaded(let loaded) = route {
      splits = HealthDatabase.splits(loaded.locations, pauses: workout.pauses)
    } else {
      splits = []
    }
  }

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989, 851-3001): the
    // workout and its figures, then a section each for heart rate, the route, splits and
    // segments.
    Form {
      Section {
        header
        summary
      }
      if !heartRates.isEmpty { heartRateSection }
      let map = RouteMapRow(route: route, height: 300)
      if map.showsSomething {
        Section("Route") { map }
      }
      if case .loaded(let loaded) = route, loaded.hasMap, !splits.isEmpty {
        splitsSection
      }
      segmentsSection
    }
    .formStyle(.grouped)
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
    .padding(.vertical, 6)
  }

  /// The figures Health shows for a workout, those it recorded, two to a line as in Health.
  private var summary: some View {
    let figures = summaryFigures
    return LazyVGrid(
      columns: [
        GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
      ],
      alignment: .leading, spacing: 12
    ) {
      ForEach(figures, id: \.label) { figure in
        WorkoutFigure(label: figure.label, value: figure.value, color: figure.color)
      }
    }
    .padding(.vertical, 6)
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

  private var heartRateSection: some View {
    let values = heartRates.compactMap(\.value)
    return Section("Heart Rate") {
      VStack(alignment: .leading, spacing: 12) {
        if let low = values.min(), let high = values.max() {
          Text("\(Int(low.rounded()))–\(Int(high.rounded())) BPM")
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(.red)
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
      .padding(.vertical, 6)
    }
  }

  // MARK: Splits

  /// A row per kilometer, under a row naming the columns.
  private var splitsSection: some View {
    Section("Splits") {
      splitRow("KM", "Time", "Pace")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(Array(splits.enumerated()), id: \.offset) { index, split in
        splitRow(
          split.distance < 990
            ? (Double(index) + split.distance / 1000).formatted(
              .number.precision(.fractionLength(2)))
            : "\(index + 1)",
          WorkoutFormat.duration(split.duration),
          WorkoutFormat.pace(split.pace), paceColor: .cyan
        )
        .monospacedDigit()
      }
    }
  }

  private func splitRow(
    _ kilometer: String, _ time: String, _ pace: String, paceColor: Color? = nil
  ) -> some View {
    HStack {
      Text(kilometer).frame(width: 50, alignment: .leading)
      Text(time).frame(maxWidth: .infinity, alignment: .leading)
      Text(pace)
        // The column names' row is secondary throughout.
        .foregroundStyle(paceColor ?? .secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  // MARK: Segments

  @ViewBuilder private var segmentsSection: some View {
    let segments = workout.decodedEvents.filter { $0.type == WorkoutEvent.segment }
    if !segments.isEmpty {
      Section("Segments") {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          LabeledContent("Segment \(index + 1)") {
            Text(WorkoutFormat.duration(segment.duration))
              .monospacedDigit()
              .foregroundStyle(.yellow)
          }
        }
      }
    }
  }
}

/// One of a workout's or a route's figures: its label, and its value in its color.
struct WorkoutFigure: View {
  let label: String
  let value: String
  let color: Color

  var body: some View {
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

extension EnvironmentValues {
  /// Whether route maps draw MapKit's map under the route, or only the route (851-2951). MapKit
  /// doesn't draw offscreen, and the grid it draws instead differs from one Mac to another, so
  /// snapshot catalogs draw only the route.
  @Entry var drawsRouteMaps = true
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

  @Environment(\.drawsRouteMaps) private var drawsMap

  var body: some View {
    if drawsMap {
      Map(initialPosition: .rect(bounds)) {
        ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
          MapPolyline(coordinates: piece.coordinates)
            .stroke(piece.color, style: Self.stroke)
        }
      }
      .mapStyle(.standard(pointsOfInterest: .excludingAll))
    } else {
      route
    }
  }

  private static let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

  /// The route alone, fitted to the view as the map fits its bounds, on a plain background.
  private var route: some View {
    Canvas { context, size in
      let scale = min(size.width / bounds.width, size.height / bounds.height)
      let origin = CGPoint(
        x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
      for piece in pieces {
        var path = Path()
        path.addLines(
          piece.coordinates.map {
            let point = MKMapPoint($0)
            return CGPoint(
              x: origin.x + (point.x - bounds.minX) * scale,
              y: origin.y + (point.y - bounds.minY) * scale)
          })
        context.stroke(path, with: .color(piece.color), style: Self.stroke)
      }
    }
    .background(.background)
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
