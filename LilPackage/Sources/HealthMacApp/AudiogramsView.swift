import Charts
import HealthDatabase
import SQLiteData
import SwiftUI

/// Audiograms, newest first and grouped by month, as in Health. Each opens its chart. Follows
/// the local database as sync changes it.
struct AudiogramsView: View {
  @Fetch private var audiograms: [HealthAudiogram]

  init() {
    _audiograms = Fetch(wrappedValue: [], RecentAudiograms(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    AudiogramsContent(
      state: $audiograms.loadError.map { .failed($0.localizedDescription) }
        ?? ($audiograms.isLoading && audiograms.isEmpty ? .loading : .loaded(audiograms)))
  }
}

/// The most recent audiograms: people have a handful.
struct RecentAudiograms: FetchKeyRequest {
  static let limit = 500

  func fetch(_ db: Database) throws -> [HealthAudiogram] {
    try HealthDatabase.audiograms(limit: Self.limit, db)
  }
}

/// What the audiogram list shows, however it got it.
struct AudiogramsContent: View {
  enum State {
    case loading
    case loaded([HealthAudiogram])
    case failed(String)
  }

  let state: State
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Audiograms", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let audiograms) where audiograms.isEmpty:
        ContentUnavailableView(
          "No Audiograms", systemImage: "ear",
          description: Text(
            "Hearing test results from AirPods Pro or a hearing test app will appear here."))
      case .loaded(let audiograms):
        List {
          ForEach(
            monthSections(audiograms, calendar: calendar, startDate: \.startDate), id: \.month
          ) { section in
            Section(section.month.formatted(.dateTime.month(.wide).year())) {
              ForEach(section.records) { audiogram in
                NavigationLink {
                  AudiogramDetailView(audiogram: audiogram)
                } label: {
                  AudiogramRow(audiogram: audiogram)
                }
              }
            }
          }
        }
      }
    }
    .navigationTitle("Audiograms")
  }
}

/// An audiogram in the list: each ear's average hearing level, and when.
struct AudiogramRow: View {
  let audiogram: HealthAudiogram

  var body: some View {
    let points = audiogram.decodedPoints
    HStack(spacing: 12) {
      Image(systemName: "ear")
        .font(.title3)
        .foregroundStyle(.blue)
        .frame(width: 36, height: 36)
        .background(.blue.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Ear.allCases, id: \.self) { ear in
          Text("\(ear == .left ? "Left" : "Right"): \(AudiogramFormat.average(points, ear))")
            .font(ear == .left ? .headline : .subheadline)
            .foregroundStyle(ear == .left ? .primary : .secondary)
        }
      }
      Spacer()
      Text(
        Date(unixMilliseconds: audiogram.startDate).formatted(date: .abbreviated, time: .omitted)
      )
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// An audiogram, as in Health: each ear's sensitivity by frequency over the hearing-loss bands,
/// and each ear's average with what it means.
struct AudiogramDetailView: View {
  let audiogram: HealthAudiogram

  var body: some View {
    let points = audiogram.decodedPoints
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(Date(unixMilliseconds: audiogram.startDate).formatted(date: .complete, time: .omitted))
          .foregroundStyle(.secondary)

        HStack(alignment: .top, spacing: 32) {
          ForEach(Ear.allCases, id: \.self) { ear in
            VStack(alignment: .leading, spacing: 4) {
              Label(ear.name, systemImage: ear == .left ? "xmark" : "circle")
                .font(.headline)
                .foregroundStyle(AudiogramFormat.color(ear))
              Text(AudiogramFormat.average(points, ear))
                .font(.system(.title, design: .rounded).weight(.semibold))
              if let level = points.averageHearingLevel(ear) {
                Text(HearingLevel(decibels: level).name)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if points.isEmpty {
          ContentUnavailableView(
            "No Results", systemImage: "ear",
            description: Text("This audiogram has no frequencies tested."))
        } else {
          AudiogramChart(points: points)
            .frame(height: 360)
        }

        LabeledContent("Recorded With", value: audiogram.sourceName)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Audiogram")
  }
}

/// Sensitivity by frequency, as audiograms are drawn: frequency on a log scale across, hearing
/// level in dBHL downward (louder sounds needed lower), the left ear as blue crosses and the
/// right as red circles, over the hearing-loss bands.
struct AudiogramChart: View {
  let points: [AudiogramPoint]

  var body: some View {
    Chart {
      ForEach(HearingLevel.allCases, id: \.self) { level in
        RectangleMark(
          yStart: .value("From", level.range.lowerBound),
          yEnd: .value("To", level.range.upperBound)
        )
        .foregroundStyle(.gray.opacity(0.06 * Double(level.rank)))
      }
      ForEach(Ear.allCases, id: \.self) { ear in
        ForEach(points.filter { $0.sensitivity(ear) != nil }, id: \.frequency) { point in
          LineMark(
            x: .value("Frequency", point.frequency),
            y: .value("Hearing Level", point.sensitivity(ear) ?? 0),
            series: .value("Ear", ear.name)
          )
          .foregroundStyle(AudiogramFormat.color(ear))
          PointMark(
            x: .value("Frequency", point.frequency),
            y: .value("Hearing Level", point.sensitivity(ear) ?? 0)
          )
          .symbol {
            Image(systemName: ear == .left ? "xmark" : "circle")
              .font(.caption.weight(.bold))
              .foregroundStyle(AudiogramFormat.color(ear))
          }
        }
      }
    }
    .chartXScale(domain: 110...9_500, type: .log)
    .chartXAxis {
      AxisMarks(values: [125, 250, 500, 1_000, 2_000, 4_000, 8_000]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let hertz = value.as(Double.self) {
            Text(hertz >= 1_000 ? "\(Int(hertz / 1_000))k" : "\(Int(hertz))")
          }
        }
      }
    }
    .chartYScale(domain: [120, -10])
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 20, 40, 60, 80, 100, 120]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let decibels = value.as(Int.self) { Text("\(decibels)") }
        }
      }
    }
    .chartYAxisLabel("dBHL", position: .leading)
    .chartXAxisLabel("Hz", position: .bottom, alignment: .trailing)
    .accessibilityLabel("Audiogram")
  }
}

extension HearingLevel {
  /// How far from normal: shades the bands.
  fileprivate var rank: Int { HearingLevel.allCases.firstIndex(of: self) ?? 0 }
}

/// How audiogram figures read.
enum AudiogramFormat {
  static func color(_ ear: Ear) -> Color { ear == .left ? .blue : .red }

  static func average(_ points: [AudiogramPoint], _ ear: Ear) -> String {
    guard let level = points.averageHearingLevel(ear) else { return "Not Tested" }
    return "\(Int(level.rounded())) dBHL"
  }
}
