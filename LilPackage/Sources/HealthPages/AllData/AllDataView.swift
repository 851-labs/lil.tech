import Dependencies
public import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Every sample of a type, newest first, in a section per day, a page at a time as the list
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
  /// From dependencies, so snapshot catalogs fix them (`previewCalendar`, `previewNow`).
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load \(type.name)", systemImage: "exclamationmark.triangle",
          description: Text(reason)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let samples, _) where samples.isEmpty:
        ContentUnavailableView(
          "No Data", systemImage: type.category?.symbolName ?? "questionmark",
          description: Text("\(type.name) synced from your iPhone will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let samples, let hasMore):
        list(samples, hasMore: hasMore)
      }
    }
    .navigationTitle("All \(type.name) Data")
  }

  /// A section per day under its name, in a grouped form's look (`LazyForm`): a grouped `Form`
  /// builds every row at once (1,000 rows take seconds, and 100,000 crash it), and a day can have
  /// hundreds, so only the rows on screen are built.
  private func list(_ samples: [HealthSample], hasMore: Bool) -> some View {
    let days = days(samples)
    // Once, so every day's header is named against the same "now".
    let now = self.now
    return LazyForm {
      ForEach(days, id: \.day) { section in
        LazyFormHeader(
          title: MetricFormat.date(section.day, isDay: true, now: now, calendar: calendar),
          isFirst: section.day == days.first?.day)
        // The last day may go on in the next page, so its section stays open while that loads.
        let isOpen = hasMore && !moreFailed && section.day == days.last?.day
        ForEach(section.samples) { sample in
          NavigationLink {
            SampleDetailView(type: type, sample: sample)
          } label: {
            LazyFormRow(
              isFirst: sample.id == section.samples.first?.id,
              isLast: !isOpen && sample.id == section.samples.last?.id
            ) {
              SampleRow(type: type, sample: sample, calendar: calendar)
            }
          }
          .buttonStyle(.plain)
        }
      }
      Group {
        if moreFailed {
          Button("Couldn't load more. Try Again", action: loadMore)
        } else if hasMore {
          // Loads the next page when the end of the list comes into view.
          ProgressView()
            .onAppear(perform: loadMore)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
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
  let calendar: Calendar

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
  }

  private var valueText: some View {
    let formatted: (number: String, unit: String)? =
      if let value = sample.value {
        MetricFormat.value(value, unit: sample.unit ?? type.unit, typeID: type.id)
      } else if let name = HealthDatabase.categoryValueName(sample.categoryValue, typeID: type.id) {
        // A category sample's value as Health names it: Stood, Moderate, Egg White (851-2828).
        (name, "")
      } else if HealthDatabase.categoryChartTypes.contains(type.id) {
        // A charted category's sample without a value to name: how long it lasted (851-2831).
        MetricFormat.duration(sample.end.timeIntervalSince(sample.start))
      } else {
        nil
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
