import Dependencies
public import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Every sample of a type, newest first and grouped by day, a page at a time as the list
/// scrolls. Each opens its details.
public struct AllDataView: View {
  let type: HealthDataType
  @Dependency(\.defaultDatabase) private var database
  @State private var state = AllDataContent.State.loading
  @State private var isLoadingMore = false
  /// The last page after the first failed to load.
  @State private var moreFailed = false

  static let pageSize = 200

  public init(type: HealthDataType) {
    self.type = type
  }

  public var body: some View {
    AllDataContent(type: type, state: state, moreFailed: moreFailed) {
      Task { await loadMore() }
    }
    .task {
      // Only the first time: coming back from a sample doesn't load another page.
      if case .loading = state { await loadMore() }
    }
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
    moreFailed = false
    defer { isLoadingMore = false }
    let (cursor, limit) = (loaded.last.map(SampleCursor.init(after:)), Self.pageSize)
    do {
      let page = try await database.read { [type] db in
        try HealthDatabase.samplePage(of: type.id, after: cursor, limit: limit, db)
      }
      state = .loaded(loaded + page, hasMore: page.count == Self.pageSize)
    } catch {
      if loaded.isEmpty {
        state = .failed(error.localizedDescription)
      } else {
        moreFailed = true
      }
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
  var moreFailed = false
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
    List {
      ForEach(days(samples), id: \.day) { section in
        Section(MetricFormat.date(section.day, isDay: true, now: now, calendar: calendar)) {
          ForEach(section.samples) { sample in
            NavigationLink {
              SampleDetailView(type: type, sample: sample)
            } label: {
              SampleRow(type: type, sample: sample, calendar: calendar)
            }
          }
        }
      }
      if moreFailed {
        Button("Couldn't load more. Try Again", action: loadMore)
          .frame(maxWidth: .infinity)
      } else if hasMore {
        // Loads the next page when the end of the list comes into view.
        ProgressView()
          .frame(maxWidth: .infinity)
          .onAppear(perform: loadMore)
      }
    }
  }

  /// The samples (newest first) by day, asking the calendar only when a sample leaves the day
  /// before it.
  private func days(_ samples: [HealthSample]) -> [(day: Date, samples: [HealthSample])] {
    var days: [(day: Date, samples: [HealthSample])] = []
    var current: DateInterval?
    for sample in samples {
      let date = Date(unixMilliseconds: sample.startDate)
      if let current, current.contains(date), !days.isEmpty {
        days[days.count - 1].samples.append(sample)
      } else {
        current = calendar.dateInterval(of: .day, for: date)
        days.append((current?.start ?? date, [sample]))
      }
    }
    return days
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
