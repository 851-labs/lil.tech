import Charts
import HealthDatabase
import SQLiteData
import SwiftUI

/// Apple Watch's beat-to-beat measurements, newest first and grouped by day, as Health lists them
/// under Heart Rate Variability. Each opens its beats. Follows the local database as sync changes
/// it.
struct HeartbeatSeriesView: View {
  @Fetch private var series: [HealthHeartbeatSeries]

  init() {
    _series = Fetch(wrappedValue: [], RecentHeartbeatSeries(), scheduler: MainQueueScheduler())
  }

  var body: some View {
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
  }

  let state: State
  /// How many the list holds at most (`RecentHeartbeatSeries.limit`), to say when it's full.
  var limit = RecentHeartbeatSeries.limit
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
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
        List {
          ForEach(
            sections(series, by: .day, calendar: calendar, startDate: \.startDate), id: \.start
          ) { section in
            Section(section.start.formatted(date: .complete, time: .omitted)) {
              ForEach(section.records) { series in
                NavigationLink {
                  HeartbeatSeriesDetailView(series: series)
                } label: {
                  HeartbeatSeriesRow(series: series)
                }
              }
            }
          }
          if series.count >= limit {
            Text("Showing the \(limit.formatted()) most recent measurements.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("Beat-to-Beat Measurements")
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
        Text("\(analysis.beatCount) beats")
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
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
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
            description: Text("This measurement has too few beats to show."))
        } else {
          Chart {
            ForEach(Array(analysis.beats.enumerated()), id: \.offset) { index, beat in
              LineMark(
                x: .value("Seconds", beat.time), y: .value("BPM", beat.beatsPerMinute),
                series: .value("Run", HeartFormat.run(analysis.beats, upTo: index))
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

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Beats", value: "\(analysis.beatCount)")
            LabeledContent(
              "Duration",
              value: "\(analysis.duration.formatted(.number.precision(.fractionLength(0)))) s")
            LabeledContent("HRV (SDNN)", value: HeartFormat.milliseconds(analysis.sdnn))
            LabeledContent("HRV (RMSSD)", value: HeartFormat.milliseconds(analysis.rmssd))
            LabeledContent("Recorded With", value: series.sourceName)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Beat-to-Beat")
  }
}

enum HeartFormat {
  static func average(_ analysis: HeartbeatAnalysis) -> String {
    guard let bpm = analysis.averageBeatsPerMinute else { return "No Average" }
    return "\(Int(bpm.rounded())) BPM Average"
  }

  static func milliseconds(_ value: Double?) -> String {
    guard let value else { return "–" }
    return "\(Int(value.rounded())) ms"
  }

  /// Which unbroken run the beat at `index` is in: gaps start a new line.
  static func run(_ beats: [HeartbeatAnalysis.Beat], upTo index: Int) -> Int {
    beats[...index].count(where: \.afterGap)
  }
}
