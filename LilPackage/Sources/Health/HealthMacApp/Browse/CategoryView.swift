import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

/// A Browse category: its metrics as rows with their latest value and week, then those without
/// data. Follows the local database as sync changes it.
struct CategoryView: View {
  let category: HealthCategory
  @Fetch var summaries: [MetricSummary]

  init(category: HealthCategory) {
    self.category = category
    // Off the main thread: a category runs a few queries per type, again after each sync write.
    _summaries = Fetch(
      wrappedValue: [], CategorySummaries(category: category),
      scheduler: MainQueueScheduler())
  }

  var body: some View {
    MetricsView(
      category: category,
      state: $summaries.loadError.map { .failed($0.localizedDescription) }
        ?? ($summaries.isLoading && summaries.isEmpty ? .loading : .loaded(summaries)))
  }
}

/// A category's summaries, as of when they're fetched.
struct CategorySummaries: FetchKeyRequest {
  let category: HealthCategory

  func fetch(_ db: Database) throws -> [MetricSummary] {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return try HealthDatabase.metricSummaries(in: category, now: now, calendar: calendar, db)
  }
}

/// What a category shows, however it got it.
struct MetricsView: View {
  enum State {
    case loading
    case loaded([MetricSummary])
    case failed(String)
  }

  let category: HealthCategory
  let state: State
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989): a section of the
    // metrics with data, a row each, then one of those without.
    Form {
      switch state {
      case .loading:
        Section {
          DelayedProgressView()
            .frame(maxWidth: .infinity, minHeight: 200)
        }
      case .failed(let reason):
        Section {
          ContentUnavailableView(
            "Couldn't Load \(category.name)", systemImage: "exclamationmark.triangle",
            description: Text(reason)
          )
          // A form's row would otherwise give it only its ideal width, off center.
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .loaded(let summaries):
        sections(summaries)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(category.name)
  }

  @ViewBuilder private func sections(_ summaries: [MetricSummary]) -> some View {
    let withData = summaries.filter(\.hasData)
    let without = summaries.filter { !$0.hasData }
    if !withData.isEmpty {
      Section {
        ForEach(withData) { summary in
          if let type = HealthCatalog.type(id: summary.id) {
            NavigationLink(value: summary.id) {
              // The page's color, for a type listed under two categories.
              MetricRow(
                type: type, summary: summary, color: category.color, now: now, calendar: calendar)
            }
          }
        }
      }
    }
    if !without.isEmpty {
      Section("No Data Available") {
        ForEach(without) { summary in
          NavigationLink(HealthCatalog.type(id: summary.id)?.name ?? summary.id, value: summary.id)
        }
      }
    }
  }
}

/// A metric's detail, by its type's ID.
struct MetricDetail: View {
  let typeID: String

  var body: some View {
    if let type = HealthCatalog.type(id: typeID) {
      MetricDetailView(type: type)
    } else {
      ContentUnavailableView("Unknown Data Type", systemImage: "questionmark")
    }
  }
}
