import ComposableArchitecture
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

/// Summary: the everyday metrics (`HealthDatabase.summaryTypes`), a row each, and highlights.
/// Follows the local database as sync changes it.
struct SummaryView: View {
  @Fetch private var summaries: [MetricSummary]
  @Fetch private var highlights: [Highlight]

  init() {
    _highlights = Fetch(wrappedValue: [], HighlightsRequest(), scheduler: MainQueueScheduler())
    _summaries = Fetch(wrappedValue: [], SummaryRequest(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    SummaryContent(
      state: $summaries.loadError.map { .failed($0.localizedDescription) }
        ?? ($summaries.isLoading && summaries.isEmpty ? .loading : .loaded(summaries)),
      highlights: $highlights.loadError.map { .failed($0.localizedDescription) }
        ?? ($highlights.isLoading && highlights.isEmpty ? .loading : .loaded(highlights))
    )
    // "Today" and the last 7 days move at midnight, even if nothing syncs.
    .onReceive(calendarDayChanges()) {
      Task { @MainActor in
        _ = try? await $highlights.load(
          HighlightsRequest(day: .now), scheduler: MainQueueScheduler())
        _ = try? await $summaries.load(SummaryRequest(day: .now), scheduler: MainQueueScheduler())
      }
    }
  }
}

/// Summary's highlights, as of when they're fetched.
struct HighlightsRequest: FetchKeyRequest {
  /// The day it's for, so a new day is a new request.
  let day: Date

  init(day: Date = .now) {
    self.day = Calendar.current.startOfDay(for: day)
  }

  func fetch(_ db: Database) throws -> [Highlight] {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return try HealthDatabase.highlights(now: now, calendar: calendar, db)
  }
}

/// Summary's metrics, as of when they're fetched.
struct SummaryRequest: FetchKeyRequest {
  /// The day it's for, so a new day is a new request.
  let day: Date

  init(day: Date = .now) {
    self.day = Calendar.current.startOfDay(for: day)
  }

  func fetch(_ db: Database) throws -> [MetricSummary] {
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return try HealthDatabase.summaryMetrics(now: now, calendar: calendar, db)
  }
}

/// What Summary shows, however it got it.
struct SummaryContent: View {
  enum State<Value> {
    case loading
    case loaded(Value)
    case failed(String)
  }

  let state: State<[MetricSummary]>
  var highlights: State<[Highlight]> = .loaded([])
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989): a section of the
    // everyday metrics, a row each, then the highlights.
    Form {
      Section {
        switch state {
        case .failed(let reason):
          ContentUnavailableView(
            "Couldn't Load Summary", systemImage: "exclamationmark.triangle",
            description: Text(reason)
          )
          // A form's row would otherwise give it only its ideal width, off center.
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The everyday metrics, a row each, as tall with data, without it, or while they load
        // (851-3092), so nothing moves when they do.
        case .loading, .loaded:
          ForEach(HealthDatabase.summaryTypes, id: \.self) { id in
            if let type = HealthCatalog.type(id: id) {
              NavigationLink(value: id) {
                MetricRow(type: type, summary: summary(id), now: now, calendar: calendar)
              }
            }
          }
        }
      }
      Section {
        highlightsSection
      } header: {
        Text("Highlights")
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutAnchor("Highlights")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Summary")
  }

  /// A metric's summary, once they've loaded: one without data if the query left it out.
  private func summary(_ id: String) -> MetricSummary? {
    guard case .loaded(let summaries) = state else { return nil }
    return summaries.first { $0.id == id } ?? MetricSummary(id: id)
  }

  @ViewBuilder private var highlightsSection: some View {
    switch highlights {
    case .loading:
      DelayedProgressView()
        .frame(maxWidth: .infinity, minHeight: 120)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Highlights", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let highlights) where highlights.isEmpty:
      Text(
        "Highlights appear once there are a couple of weeks of steps, energy, heart or weight data to compare."
      )
      .foregroundStyle(.secondary)
    case .loaded(let highlights):
      ForEach(highlights) { highlight in
        if let type = HealthCatalog.type(id: highlight.typeID) {
          NavigationLink(value: highlight.typeID) {
            HighlightRow(highlight: highlight, type: type)
          }
        }
      }
    }
  }
}
