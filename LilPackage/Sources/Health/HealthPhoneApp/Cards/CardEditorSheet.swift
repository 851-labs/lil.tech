import ComposableArchitecture
import Dependencies
import HealthCardEditor
import HealthCards
import HealthKitAccess
import HealthUI
import SwiftUI

// The card editor on the iPhone (851-3213, docs/decisions/cards.md, UI › iPhone): the Mac's editor
// and query builder (`CardEditorView`, shared), a sheet with its own navigation stack, which the
// symbol and type pickers push on, and a live preview from this iPhone's HealthKit.

/// The editor's sheet. Swiping it down is off while it holds changes, so they're only lost by
/// Cancel.
struct CardEditorSheet: View {
  let store: StoreOf<CardEditorFeature>

  var body: some View {
    NavigationStack {
      CardEditorView(store: store) { CardEditorPreview(spec: $0) }
    }
    .interactiveDismissDisabled(store.hasChanges)
  }
}

/// The editor's live preview, from this iPhone's HealthKit: the card at its range, on the period
/// with its latest data, as its page opens (851-3188). The last spec's stays, with the delayed
/// spinner, while the next loads (851-3084, 851-3086).
struct CardEditorPreview: View {
  let spec: CardSpec?
  /// The period loaded last, for `query`, and the spec it was loaded for, which draws it until the
  /// next arrives.
  @State private var chart: CardPeriod?
  @State private var chartSpec: CardSpec?
  @State private var failure: String?
  @State private var isLoading = false
  @Dependency(\.healthKitCards) private var healthKitCards
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  /// What the data depends on: the spec without its name, symbol and color, so choosing those
  /// runs nothing again.
  private var query: CardSpec? { spec?.withoutAppearance }

  var body: some View {
    CardPreviewContent(spec: spec, state: state, offset: chart?.offset ?? 0)
      .task(id: query) { await load() }
  }

  private var state: CardChart.State {
    if let failure { return .failed(failure) }
    guard let chart, let spec else { return .loading }
    // The data drawn as the spec looks now, or as the spec it's for did while the next loads.
    let isCurrent = chart.spec == query
    let period = CardPeriod(
      range: chart.range, offset: chart.offset, spec: isCurrent ? spec : chartSpec ?? spec,
      data: chart.data)
    return .loaded(period, isUpdating: isLoading || !isCurrent)
  }

  private func load() async {
    guard let query, let spec else { return }
    let now = date.now
    isLoading = true
    failure = nil
    defer { if !Task.isCancelled { isLoading = false } }
    do {
      let range = query.range
      let latest = try await healthKitCards.headlineOffMain(query, now: now, calendar: calendar)
      try Task.checkCancellation()
      let offset = range.openingOffset(latest: latest?.date, now: now, calendar: calendar)
      let period = range.interval(offset: offset, now: now, calendar: calendar)
      let data = try await healthKitCards.dataOffMain(
        query, range: range, date: period.start, now: now, calendar: calendar)
      try Task.checkCancellation()
      chart = CardPeriod(range: range, offset: offset, spec: query, data: data)
      chartSpec = spec
    } catch {
      guard !(error is CancellationError), !Task.isCancelled else { return }
      failure = error.localizedDescription
    }
  }
}
