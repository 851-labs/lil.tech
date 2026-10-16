import Dependencies
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// Every sample of a type, newest first and grouped by day, a page at a time as the list
/// scrolls. Each opens its details.
struct AllDataView: View {
  let type: HealthDataType
  @Dependency(\.defaultDatabase) private var database
  @State private var state = AllDataContent.State.loading
  @State private var isLoadingMore = false

  static let pageSize = 200

  var body: some View {
    AllDataContent(type: type, state: state) {
      Task { await loadMore() }
    }
    .task { await loadMore() }
  }

  private func loadMore() async {
    let loaded: [HealthSample]
    switch state {
    case .loaded(let samples, hasMore: true): loaded = samples
    case .loading: loaded = []
    case .loaded, .failed: return
    }
    guard !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    let (cursor, limit) = (loaded.last.map(SampleCursor.init(after:)), Self.pageSize)
    do {
      let page = try await database.read { [type] db in
        try HealthDatabase.samplePage(of: type.id, after: cursor, limit: limit, db)
      }
      state = .loaded(loaded + page, hasMore: page.count == Self.pageSize)
    } catch {
      if loaded.isEmpty { state = .failed(error.localizedDescription) }
    }
  }
}

/// What All Data shows, however it got it.
struct AllDataContent: View {
  enum State {
    case loading
    case loaded([HealthSample], hasMore: Bool)
    case failed(String)
  }

  let type: HealthDataType
  let state: State
  let loadMore: () -> Void
  var calendar = Calendar.current
  var now = Date.now

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load \(type.name)", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let samples, _) where samples.isEmpty:
        ContentUnavailableView(
          "No Data", systemImage: type.category?.symbolName ?? "questionmark",
          description: Text("\(type.name) synced from your iPhone will appear here."))
      case .loaded(let samples, let hasMore):
        list(samples, hasMore: hasMore)
      }
    }
    .navigationTitle("All \(type.name) Data")
  }

  private func list(_ samples: [HealthSample], hasMore: Bool) -> some View {
    let days = Dictionary(grouping: samples) {
      calendar.startOfDay(for: Date(unixMilliseconds: $0.startDate))
    }
    .sorted { $0.key > $1.key }
    return List {
      ForEach(days, id: \.key) { day, samples in
        Section(MetricFormat.date(day, isDay: true, now: now, calendar: calendar)) {
          ForEach(samples) { sample in
            NavigationLink {
              SampleDetailView(type: type, sample: sample)
            } label: {
              SampleRow(type: type, sample: sample, calendar: calendar)
            }
            .onAppear {
              if sample.id == samples.last?.id, day == days.last?.key { loadMore() }
            }
          }
        }
      }
      if hasMore {
        ProgressView()
          .frame(maxWidth: .infinity)
          .onAppear(perform: loadMore)
      }
    }
  }
}

/// One sample: its value, where it came from, and when.
struct SampleRow: View {
  let type: HealthDataType
  let sample: HealthSample
  var calendar = Calendar.current

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        valueText
        Text(sample.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(SampleFormat.time(sample, calendar: calendar))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  private var valueText: some View {
    let formatted = sample.value.map {
      MetricFormat.value($0, unit: sample.unit ?? type.unit, typeID: type.id)
    }
    return HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(formatted?.number ?? "–")
        .font(.body.weight(.semibold))
      if let unit = formatted?.unit {
        Text(unit)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// How a sample's times read.
enum SampleFormat {
  /// "9:41 AM", or "9:41 – 10:05 AM" for a sample that lasts more than a minute.
  static func time(_ sample: HealthSample, calendar: Calendar) -> String {
    let start = Date(unixMilliseconds: sample.startDate)
    let end = Date(unixMilliseconds: sample.endDate)
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()
    guard end.timeIntervalSince(start) > 60 else { return start.formatted(style) }
    return (start..<end).formatted(
      Date.IntervalFormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
  }

  /// A metadata key as words: `HKMetadataKeyHeartRateMotionContext` reads "Heart Rate Motion
  /// Context". Other apps' keys are left as they are.
  static func key(_ key: String) -> String {
    guard key.hasPrefix("HKMetadataKey") else { return key }
    var words = ""
    for character in key.dropFirst("HKMetadataKey".count) {
      if character.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
      words.append(character)
    }
    return words
  }
}
