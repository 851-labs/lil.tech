import Dependencies
import HealthCatalog
import HealthDatabase
import LilUI
import SQLiteData
public import SwiftUI

/// Workouts, newest first and grouped by month, as in Health. Each opens its detail. Follows the
/// local database as sync changes it.
///
/// With `onlyWithRoutes`, it's Workout Routes (851-2835): the workouts with a route, then the
/// routes no workout shows, each opening on a map.
public struct WorkoutsView: View {
  private let onlyWithRoutes: Bool
  @Fetch private var list: WorkoutList

  public init(onlyWithRoutes: Bool = false) {
    self.onlyWithRoutes = onlyWithRoutes
    _list = Fetch(
      wrappedValue: WorkoutList(), RecentWorkouts(onlyWithRoutes: onlyWithRoutes),
      scheduler: MainQueueScheduler())
  }

  public var body: some View {
    WorkoutsContent(
      state: $list.loadError.map { .failed($0.localizedDescription) }
        ?? ($list.isLoading && list.isEmpty
          ? .loading : .loaded(list.workouts, otherRoutes: list.otherRoutes)),
      onlyWithRoutes: onlyWithRoutes)
  }
}

/// What Workouts lists.
struct WorkoutList: Equatable, Sendable {
  var workouts: [HealthWorkout] = []
  /// Routes no workout shows, for Workout Routes.
  var otherRoutes: [HealthWorkoutRoute] = []

  var isEmpty: Bool { workouts.isEmpty && otherRoutes.isEmpty }
}

/// The most recent workouts (years of them for most people), or those with routes, and the
/// routes no workout shows.
struct RecentWorkouts: FetchKeyRequest {
  static let limit = 2_000

  var onlyWithRoutes = false

  func fetch(_ db: Database) throws -> WorkoutList {
    guard onlyWithRoutes else {
      return WorkoutList(workouts: try HealthDatabase.workouts(limit: Self.limit, db))
    }
    let (workouts, otherRoutes) = try HealthDatabase.workoutRoutes(limit: Self.limit, db)
    return WorkoutList(workouts: workouts, otherRoutes: otherRoutes)
  }
}

/// What Workouts shows, however it got it.
struct WorkoutsContent: View {
  enum State {
    case loading
    case loaded([HealthWorkout], otherRoutes: [HealthWorkoutRoute] = [])
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let state: State
  /// Workout Routes rather than Workouts.
  var onlyWithRoutes = false
  /// How many each list holds at most (`RecentWorkouts.limit`), to say when it's full.
  var limit = RecentWorkouts.limit
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      case .loading:
        // Its space, under the spinner `delayedProgress` shows (851-3086).
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          onlyWithRoutes ? "Couldn't Load Workout Routes" : "Couldn't Load Workouts",
          systemImage: "exclamationmark.triangle", description: Text(reason))
      case .loaded(let workouts, let otherRoutes) where workouts.isEmpty && otherRoutes.isEmpty:
        if onlyWithRoutes {
          ContentUnavailableView(
            "No Workout Routes", systemImage: "map",
            description: Text("Routes from your outdoor workouts will appear here."))
        } else {
          ContentUnavailableView(
            "No Workouts", systemImage: "figure.run",
            description: Text("Workouts from your Apple Watch and fitness apps will appear here."))
        }
      case .loaded(let workouts, let otherRoutes):
        list(workouts, otherRoutes: otherRoutes)
      }
    }
    .delayedProgress(isLoading: state.isLoading)
    .navigationTitle(onlyWithRoutes ? "Workout Routes" : "Workouts")
  }

  /// A section per month, then Other Routes, in a grouped list (`LazyGroupedList`): a `Form`
  /// builds every row at once, and the list holds up to 2,000 workouts.
  private func list(_ workouts: [HealthWorkout], otherRoutes: [HealthWorkoutRoute]) -> some View {
    let months = sections(workouts, by: .month, calendar: calendar, startDate: \.startDate)
    return LazyGroupedList {
      ForEach(months, id: \.start) { month in
        Section {
          ForEach(month.records) { workout in
            NavigationLink {
              WorkoutDetailView(workout: workout)
            } label: {
              WorkoutRow(workout: workout)
            }
          }
        } header: {
          Text(month.start.formatted(.dateTime.month(.wide).year()))
        } footer: {
          // Under the workouts, not at the end of the page, which Other Routes may follow.
          if month.start == months.last?.start, workouts.count >= limit {
            Text(limitNote(onlyWithRoutes ? "workouts with routes" : "workouts"))
          }
        }
      }
      if !otherRoutes.isEmpty {
        Section {
          ForEach(otherRoutes) { route in
            NavigationLink {
              RouteDetailView(route: route)
            } label: {
              OtherRouteRow(route: route)
            }
          }
        } header: {
          Text("Other Routes")
        } footer: {
          if otherRoutes.count >= limit {
            Text(limitNote("other routes"))
          }
        }
      }
    }
  }

  /// That a list stops at the limit: "Showing the 2,000 most recent workouts."
  private func limitNote(_ what: String) -> String {
    "Showing the \(limit.formatted()) most recent \(what)."
  }
}

/// A workout in the list: its activity, the figure that matters most for it, and when.
struct WorkoutRow: View {
  let workout: HealthWorkout
  /// For its distance's unit (851-3176).
  @Dependency(\.locale) private var locale

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: WorkoutActivity.symbol(workout.activityType))
        .font(.title3)
        .foregroundStyle(.green)
        .frame(width: 36, height: 36)
        .background(.green.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(WorkoutActivity.name(workout.activityType))
          .font(.headline)
        Text(WorkoutFormat.headline(workout, workout.decodedStatistics, locale: locale))
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(.green)
      }
      Spacer()
      Text(Date(unixMilliseconds: workout.startDate).formatted(date: .abbreviated, time: .omitted))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// How workouts' figures read, in the locale's units (851-3176): distances in km or mi (a swim's
/// in its pool's m or yd), paces and splits per km or per mi, as `MetricFormat` picks them for
/// the type. Stored values stay in SI.
enum WorkoutFormat {
  static let activeEnergy = HealthWorkout.activeEnergyType
  static let basalEnergy = "HKQuantityTypeIdentifierBasalEnergyBurned"
  static let heartRate = HealthWorkout.heartRateType
  static let walkingRunningDistance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
  static let swimmingDistance = "HKQuantityTypeIdentifierDistanceSwimming"

  /// The workout's distance in meters, whichever kind it recorded, and the unit it's shown in:
  /// that kind's, km or mi by the locale, except a swim's, in the pool's unit as Health shows it
  /// (`swimmingUnit`).
  static func distance(
    of workout: HealthWorkout, _ statistics: [String: WorkoutStatistic], locale: Locale
  ) -> (meters: Double, unit: MetricFormat.DisplayUnit)? {
    for type in HealthWorkout.distanceTypes {
      guard let meters = statistics[type]?.sum else { continue }
      let unit =
        type == swimmingDistance
        ? swimmingUnit(workout, locale: locale)
        : MetricFormat.unit("m", typeID: type, locale: locale)
      return (meters, unit)
    }
    return nil
  }

  /// A swim's distance unit, as Health shows it: the pool's (its lap length's, metres or yards,
  /// whatever the locale), or the locale's when it has none (open water, or an app that doesn't
  /// say): yards in the US, metres elsewhere.
  static func swimmingUnit(_ workout: HealthWorkout, locale: Locale) -> MetricFormat.DisplayUnit {
    // A quantity's description, "25 yd" or "50 m" (`HealthEncoder.json`).
    let metadata =
      workout.metadata.flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      } ?? [:]
    let lapUnit = (metadata["HKLapLength"] as? String)?.split(separator: " ").last
    switch lapUnit {
    case "yd": return MetricFormat.swimmingUnit(yards: true, locale: locale)
    case "m": return MetricFormat.swimmingUnit(yards: false, locale: locale)
    default: return MetricFormat.unit("m", typeID: swimmingDistance, locale: locale)
    }
  }

  /// The unit a route's distance and splits are in: a kilometer or a mile, whatever the
  /// activity, as Health splits them.
  static func splitUnit(locale: Locale) -> MetricFormat.DisplayUnit {
    MetricFormat.unit("m", typeID: walkingRunningDistance, locale: locale)
  }

  /// The route cut into `unit`'s lengths, 1,000 or 1,609.344 m: recomputed per mile, not
  /// kilometers relabelled.
  static func splits(
    _ locations: [RouteLocation], pauses: [DateInterval], in unit: MetricFormat.DisplayUnit
  ) -> [RouteSplit] {
    HealthDatabase.splits(locations, pauses: pauses, every: 1 / unit.scale)
  }

  /// `meters` in `unit`: "5.02 km" or "3.12 mi", with two decimals as Health writes a workout's,
  /// or "1,500 m" for a swim.
  static func distance(_ meters: Double, in unit: MetricFormat.DisplayUnit) -> String {
    let shown = unit.convert(meters)
    let number =
      unit.label == "km" || unit.label == "mi"
      ? shown.formatted(.number.precision(.fractionLength(2)).locale(unit.locale))
      : unit.format(shown)
    return "\(number) \(unit.label)"
  }

  /// Distance if it has one, otherwise active energy, otherwise its time.
  static func headline(
    _ workout: HealthWorkout, _ statistics: [String: WorkoutStatistic], locale: Locale
  ) -> String {
    if let (meters, unit) = distance(of: workout, statistics, locale: locale), meters > 0 {
      return distance(meters, in: unit)
    }
    if let energy = statistics[activeEnergy]?.sum, energy > 0 {
      return self.energy(energy, locale: locale)
    }
    return duration(workout.duration)
  }

  /// "412 kcal", in `MetricFormat`'s unit for energy, which no locale changes.
  static func energy(_ kilocalories: Double, locale: Locale) -> String {
    let (number, unit) = MetricFormat.value(
      kilocalories, unit: "kcal", typeID: activeEnergy, locale: locale)
    return "\(number) \(unit)"
  }

  /// "0:42:18", or "42:18" under an hour, as Health shows workout times.
  static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }

  /// `seconds` to cover `meters`, per `unit`'s one: "5'12\"/km", "8'22\"/mi".
  static func pace(_ seconds: TimeInterval, over meters: Double, in unit: MetricFormat.DisplayUnit)
    -> String
  {
    let per = seconds / unit.convert(meters)
    guard per.isFinite, per >= 0 else { return "–" }
    let total = Int(per.rounded())
    return String(format: "%d'%02d\"/%@", total / 60, total % 60, unit.label)
  }
}
