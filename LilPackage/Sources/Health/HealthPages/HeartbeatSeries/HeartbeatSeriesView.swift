import Charts
import Dependencies
import HealthDatabase
import HealthUI
import LilUI
import SQLiteData
public import SwiftUI

/// Apple Watch's beat-to-beat measurements, newest first and grouped by day, as Health lists them
/// under Heart Rate Variability. Each opens its beats. Follows the local database as sync changes
/// it.
public struct HeartbeatSeriesView: View {
  @Fetch private var series: [HealthHeartbeatSeries]

  public init() {
    _series = Fetch(wrappedValue: [], RecentHeartbeatSeries(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    HeartbeatSeriesContent(
      state: $series.loadError.map { .failed($0.localizedDescription) }
        ?? ($series.isLoading && series.isEmpty ? .loading : .loaded(series)))
  }
}

struct RecentHeartbeatSeries: FetchKeyRequest {
  static let limit = 1_000

  func fetch(_ db: Database) throws -> [HealthHeartbeatSeries] {
    try HealthDatabase.heartbeatSeries(limit: Self.limit, db)
  }
}

/// What the list of series shows, however it got it.
struct HeartbeatSeriesContent: View {
  enum State {
    case loading
    case loaded([HealthHeartbeatSeries])
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let state: State
  /// How many the list holds at most (`RecentHeartbeatSeries.limit`), to say when it's full.
  var limit = RecentHeartbeatSeries.limit
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
          "Couldn't Load Beat-to-Beat Measurements", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let series) where series.isEmpty:
        ContentUnavailableView(
          "No Beat-to-Beat Measurements", systemImage: "heart.text.square",
          description: Text(
            "Apple Watch measures the time between heartbeats while you're still, and after a Breathe session."
          ))
      case .loaded(let series):
        list(series)
      }
    }
    .delayedProgress(isLoading: state.isLoading)
    .navigationTitle("Beat-to-Beat Measurements")
  }

  /// A section per day, in a grouped list (`LazyGroupedList`): a `Form` builds every row at once,
  /// and the list holds up to 1,000.
  private func list(_ series: [HealthHeartbeatSeries]) -> some View {
    let days = sections(series, by: .day, calendar: calendar, startDate: \.startDate)
    return LazyGroupedList {
      ForEach(days, id: \.start) { day in
        Section {
          ForEach(day.records) { series in
            NavigationLink {
              // Built when opened: it works out the series' beats.
              Lazy { HeartbeatSeriesDetailView(series: series) }
            } label: {
              HeartbeatSeriesRow(series: series)
            }
          }
        } header: {
          Text(day.start.formatted(date: .complete, time: .omitted))
        } footer: {
          if day.start == days.last?.start, series.count >= limit {
            Text("Showing the \(limit.formatted()) most recent measurements.")
          }
        }
      }
    }
  }
}

/// A series in the list: its beats and average heart rate, and when.
struct HeartbeatSeriesRow: View {
  let series: HealthHeartbeatSeries
  /// Worked out once, not on every render.
  private let analysis: HeartbeatAnalysis

  init(series: HealthHeartbeatSeries) {
    self.series = series
    analysis = series.analysis
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "heart.text.square")
        .font(.title3)
        .foregroundStyle(.red)
        .frame(width: 36, height: 36)
        .background(.red.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(HeartFormat.average(analysis))
          .font(.headline)
        Text("\(analysis.beatCount.formatted()) beats")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(Date(unixMilliseconds: series.startDate).formatted(date: .omitted, time: .shortened))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// A series' beats, as in Health: the heart rate between each pair of beats over the series
/// (a tachogram), and its average and variability.
struct HeartbeatSeriesDetailView: View {
  let series: HealthHeartbeatSeries
  private let analysis: HeartbeatAnalysis

  init(series: HealthHeartbeatSeries) {
    self.series = series
    analysis = series.analysis
  }

  var body: some View {
    // A grouped form, as Metric Detail is (851-2989, 851-3032): the average and the beats' chart,
    // then the series' figures.
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(HeartFormat.average(analysis))
              .font(.largeTitle.bold())
            Text(
              Date(unixMilliseconds: series.startDate).formatted(date: .complete, time: .shortened)
            )
            .foregroundStyle(.secondary)
          }
          if analysis.beats.isEmpty {
            ContentUnavailableView(
              "No Beats", systemImage: "heart.text.square",
              description: Text("This measurement has too few beats to show.")
            )
            // In the chart's place, as tall.
            .frame(maxWidth: .infinity, minHeight: 260)
          } else {
            Chart {
              ForEach(analysis.beats, id: \.time) { beat in
                LineMark(
                  x: .value("Seconds", beat.time), y: .value("BPM", beat.beatsPerMinute),
                  series: .value("Run", beat.run)
                )
                .foregroundStyle(.red)
                PointMark(x: .value("Seconds", beat.time), y: .value("BPM", beat.beatsPerMinute))
                  .foregroundStyle(.red)
                  .symbolSize(18)
              }
            }
            .chartXAxisLabel("Seconds")
            .chartYAxisLabel("BPM")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 260)
          }
        }
        .padding(.vertical, 6)
      }
      Section {
        LabeledContent("Beats", value: analysis.beatCount.formatted())
        LabeledContent(
          "Duration",
          value: "\(analysis.duration.formatted(.number.precision(.fractionLength(0)))) s")
        LabeledContent("HRV (SDNN)", value: HeartFormat.milliseconds(analysis.sdnn))
        LabeledContent("HRV (RMSSD)", value: HeartFormat.milliseconds(analysis.rmssd))
        LabeledContent("Recorded With", value: series.sourceName)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Beat-to-Beat")
  }
}

enum HeartFormat {
  static func average(_ analysis: HeartbeatAnalysis) -> String {
    guard let bpm = analysis.averageBeatsPerMinute else { return "No Average" }
    let (number, unit) = MetricFormat.value(
      bpm, unit: "count/min", typeID: HealthDatabase.heartRateType)
    return "\(number) \(unit) Average"
  }

  static func milliseconds(_ value: Double?) -> String {
    guard let value else { return "–" }
    let (number, unit) = MetricFormat.value(
      value, unit: "ms", typeID: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
    return "\(number) \(unit)"
  }
}
