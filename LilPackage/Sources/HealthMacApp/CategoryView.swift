import Charts
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// A Browse category: its metrics as cards with their latest value and week, then those without
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
        ?? ($summaries.isLoading ? .loading : .loaded(summaries)))
  }
}

/// Fetches in the background and delivers on the main queue, even the first value.
struct MainQueueScheduler: ValueObservationScheduler, Hashable {
  func immediateInitialValue() -> Bool { false }

  func schedule(_ action: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async(execute: action)
  }
}

/// A category's summaries, as of when they're fetched.
struct CategorySummaries: FetchKeyRequest {
  let category: HealthCategory

  func fetch(_ db: Database) throws -> [MetricSummary] {
    try HealthDatabase.metricSummaries(in: category, now: .now, calendar: .current, db)
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
  var now = Date.now

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load \(category.name)", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let summaries):
        list(summaries)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.groupedBackground)
    .navigationTitle(category.name)
  }

  private func list(_ summaries: [MetricSummary]) -> some View {
    let withData = summaries.filter(\.hasData)
    let without = summaries.filter { !$0.hasData }
    return ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(withData) { summary in
          if let type = HealthCatalog.type(id: summary.id) {
            NavigationLink(value: summary.id) {
              MetricCard(type: type, summary: summary, color: category.color, now: now)
            }
            .buttonStyle(.plain)
          }
        }
        if !without.isEmpty {
          Text("No Data Available")
            .font(.title3.bold())
            .padding(.top, withData.isEmpty ? 0 : 14)
          VStack(spacing: 0) {
            ForEach(Array(without.enumerated()), id: \.element.id) { index, summary in
              if index > 0 { Divider().padding(.leading, 14) }
              NavigationLink(value: summary.id) {
                HStack {
                  Text(HealthCatalog.type(id: summary.id)?.name ?? summary.id)
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
  }
}

/// One metric with data: its name, when it's from, its latest value and a week's chart.
struct MetricCard: View {
  let type: HealthDataType
  let summary: MetricSummary
  let color: Color
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(type.name, systemImage: type.category?.symbolName ?? "circle")
          .font(.headline)
          .foregroundStyle(color)
        Spacer()
        if let date = summary.latestDate {
          Text(
            MetricFormat.date(date, isDay: summary.isDailyTotal, now: now, calendar: .current)
          )
          .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.caption.bold())
          .foregroundStyle(.tertiary)
      }
      if let value = summary.latestValue {
        HStack(alignment: .bottom) {
          let (number, unit) = MetricFormat.value(value, unit: summary.unit, typeID: type.id)
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(number)
              .font(.system(.title, design: .rounded).bold())
            Text(unit)
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Sparkline(days: summary.days, isTotals: summary.isDailyTotal, color: color)
            .frame(width: 120, height: 36)
        }
      }
    }
    .padding(14)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    .contentShape(RoundedRectangle(cornerRadius: 12))
  }
}

/// A week at a glance: bars for daily totals, a line for daily averages.
struct Sparkline: View {
  let days: [DailyValue]
  let isTotals: Bool
  let color: Color

  var body: some View {
    Chart(days, id: \.day) { day in
      if isTotals {
        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color.opacity(0.8))
      } else {
        LineMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color)
        PointMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color)
          .symbolSize(12)
      }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
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

extension Color {
  /// Health's page behind cards: light gray, or black in dark mode.
  static let groupedBackground = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(white: 0, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })

  /// A card on `groupedBackground`.
  static let cardBackground = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(white: 0.11, alpha: 1) : .white
    })
}
