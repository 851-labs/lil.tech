import Charts
import Dependencies
import HealthCatalog
import HealthDatabase
import HealthUI
import LilSync
import MapKit
import SQLiteData
import SwiftUI

/// A workout, as in Health: its summary figures (with its effort score) and recorded time zone,
/// heart rate over the workout, the route colored by pace with its splits (per kilometer or mile,
/// by the locale), a multisport workout's legs, and its segments.
struct WorkoutDetailView: View {
  let workout: HealthWorkout
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.blobCache) private var blobCache
  /// Its heart rate and effort scores, read by the view's task and followed, so links and scores
  /// that sync while it's open show (a score is often rated after the workout).
  @ThrottledFetch private var linked = WorkoutLinkedData()
  /// `.none` until the workout's route is known to exist: a workout without one never shows a
  /// placeholder for it (851-3091).
  @State private var route = RouteState.none

  var body: some View {
    WorkoutDetailContent(
      workout: workout, heartRates: linked.heartRates, effort: linked.effort, route: route
    )
    .task(id: workout.id) {
      // Both from the local database, set one after the other, so the heart rate and the
      // route's placeholder arrive at once, and only then the route, which may have to be
      // downloaded.
      await $linked.load(
        WorkoutLinkedDataRequest(workout: workout), tables: HealthDatabase.workoutLinkTables)
      switch await routeRow(workout) {
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

/// What a workout's page reads besides its row: its heart rate (linked, or guessed until its
/// links sync, `HealthDatabase.workoutHeartRates`) and effort scores.
struct WorkoutLinkedData: Equatable, Sendable {
  var heartRates = WorkoutHeartRates()
  var effort: WorkoutEffort?
}

struct WorkoutLinkedDataRequest: FetchKeyRequest {
  let workout: HealthWorkout

  /// By its ID: equal requests are equal workouts, as `HealthWorkout` compares them.
  func hash(into hasher: inout Hasher) { hasher.combine(workout.id) }

  func fetch(_ db: Database) throws -> WorkoutLinkedData {
    // Read on their own: effort scores that can't be read leave the heart rate.
    WorkoutLinkedData(
      heartRates: try HealthDatabase.workoutHeartRates(of: workout, db),
      effort: try? HealthDatabase.workoutEffort(of: workout.id, db))
  }
}

/// What a workout's detail shows, however it got it.
struct WorkoutDetailContent: View {
  let workout: HealthWorkout
  let heartRates: WorkoutHeartRates
  let effort: WorkoutEffort?
  let route: RouteState
  /// Decoded and worked out once, not on every render.
  private let statistics: [String: WorkoutStatistic]
  private let splits: [RouteSplit]
  /// What distances, paces and splits are in, by the locale (851-3176).
  private let locale: Locale
  /// A kilometer or a mile.
  private let splitUnit: MetricFormat.DisplayUnit
  /// How far it went, and in what (`WorkoutFormat.distance`).
  private let distance: (meters: Double, unit: MetricFormat.DisplayUnit)?
  /// The zone it was recorded in, if it has one (851-4179).
  private let timeZone: RecordedTimeZone?
  /// A multisport workout's legs; none for one activity.
  private let legs: [WorkoutActivityRecord]

  init(
    workout: HealthWorkout, heartRates: WorkoutHeartRates, effort: WorkoutEffort? = nil,
    route: RouteState
  ) {
    self.workout = workout
    self.heartRates = heartRates
    self.effort = effort
    self.route = route
    let activities = workout.decodedActivities
    legs = activities.count > 1 ? activities : []
    @Dependency(\.locale) var locale
    self.locale = locale
    statistics = workout.decodedStatistics
    splitUnit = WorkoutFormat.splitUnit(locale: locale)
    distance = WorkoutFormat.distance(of: workout, statistics, locale: locale)
    @Dependency(\.calendar) var calendar
    timeZone = RecordedTimeZone(
      workout.decodedMetadata.timeZoneName, start: Date(unixMilliseconds: workout.startDate),
      calendar: calendar)
    if case .loaded(let loaded) = route {
      splits = WorkoutFormat.splits(loaded.locations, pauses: workout.pauses, in: splitUnit)
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
        if let timeZone { RecordedTimeZoneRow(zone: timeZone) }
      }
      if !heartRates.samples.isEmpty { heartRateSection }
      let map = RouteMapRow(route: route, height: 300)
      if map.showsSomething {
        Section("Route") { map }
      }
      if case .loaded(let loaded) = route, loaded.hasMap, !splits.isEmpty {
        splitsSection
      }
      if !legs.isEmpty { legsSection }
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
    if let (meters, unit) = distance, meters > 0 {
      figures.append(("Distance", WorkoutFormat.distance(meters, in: unit), .cyan))
      if WorkoutActivity.hasPace(workout.activityType), workout.duration > 0 {
        figures.append(
          ("Avg. Pace", WorkoutFormat.pace(workout.duration, over: meters, in: unit), .cyan))
      }
    }
    let active = statistics[WorkoutFormat.activeEnergy]?.sum
    if let active {
      figures.append(("Active Calories", WorkoutFormat.energy(active, locale: locale), .pink))
    }
    if let active, let basal = statistics[WorkoutFormat.basalEnergy]?.sum {
      figures.append(
        ("Total Calories", WorkoutFormat.energy(active + basal, locale: locale), .pink))
    }
    if let average = statistics[WorkoutFormat.heartRate]?.average {
      figures.append(("Avg. Heart Rate", "\(Int(average.rounded())) BPM", .red))
    }
    if let score = effort?.score, let value = WorkoutFormat.effort(score) {
      figures.append((WorkoutFormat.effortLabel(score), value, .orange))
    }
    return figures.map { (label: $0.0, value: $0.1, color: $0.2) }
  }

  // MARK: Heart rate

  private var heartRateSection: some View {
    let values = heartRates.samples.compactMap(\.value)
    return Section {
      VStack(alignment: .leading, spacing: 12) {
        if let low = values.min(), let high = values.max() {
          Text("\(Int(low.rounded()))–\(Int(high.rounded())) BPM")
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(.red)
        }
        Chart(heartRates.samples) { sample in
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
    } header: {
      Text("Heart Rate")
    } footer: {
      if let footer = heartRateFooter { Text(footer) }
    }
  }

  /// Says when the chart is a guess (851-4186): the readings during the workout of the source
  /// that recorded the most, not those its app added to it.
  private var heartRateFooter: String? {
    let source = heartRates.samples.first?.sourceName ?? ""
    switch heartRates.origin {
    case .linked:
      return nil
    case .notSynced:
      return
        "Readings by \(source) during the workout. Which readings belong to it hasn't synced from your iPhone yet."
    case .tooMany:
      return
        "Readings by \(source) during the workout. It recorded too many samples for lil health to sync which belong to it."
    }
  }

  // MARK: Legs

  /// A multisport workout's legs, in order: each one's activity, time and effort score.
  private var legsSection: some View {
    Section("Legs") {
      ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
        LabeledContent {
          VStack(alignment: .trailing, spacing: 2) {
            Text(WorkoutFormat.duration(leg.duration))
              .monospacedDigit()
              .foregroundStyle(.yellow)
            if let score = leg.id.flatMap({ effort?.legs[$0] }),
              let value = WorkoutFormat.effort(score)
            {
              Text("\(WorkoutFormat.effortLabel(score)) \(value)")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        } label: {
          Label(
            WorkoutActivity.name(leg.activityType),
            systemImage: WorkoutActivity.symbol(leg.activityType))
        }
      }
    }
  }

  // MARK: Splits

  /// A row per kilometer or mile, under a row naming the columns. The last, shorter one is
  /// numbered by how far the route went: 5.02.
  private var splitsSection: some View {
    Section("Splits") {
      splitRow(splitUnit.label.uppercased(), "Time", "Pace")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(Array(splits.enumerated()), id: \.offset) { index, split in
        let length = splitUnit.convert(split.distance)
        splitRow(
          length < 0.99
            ? (Double(index) + length).formatted(
              .number.precision(.fractionLength(2)).locale(locale))
            : (index + 1).formatted(.number.locale(locale)),
          WorkoutFormat.duration(split.duration),
          WorkoutFormat.pace(split.duration, over: split.distance, in: splitUnit),
          paceColor: .cyan
        )
        .monospacedDigit()
      }
    }
  }

  private func splitRow(
    _ number: String, _ time: String, _ pace: String, paceColor: Color? = nil
  ) -> some View {
    HStack {
      Text(number).frame(width: 50, alignment: .leading)
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
