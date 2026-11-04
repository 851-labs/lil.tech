import HealthCardEditor
import HealthCards
import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// The Mac's live preview for the card editor (851-3208), from the local database.

/// The editor's live preview, from the local database: the card at its range, on the period its
/// page opens on (851-3188, 851-3987). The last spec's stays, with the delayed
/// spinner, while the next loads (851-3084, 851-3086).
struct CardEditorPreview: View {
  let spec: CardSpec?
  @Fetch private var chart: CardPeriod? = nil

  /// What the data depends on: the spec without its name, symbol and color, so choosing those
  /// runs nothing again.
  private var query: CardSpec? { spec?.withoutAppearance }

  var body: some View {
    CardPreviewContent(spec: spec, state: state, offset: chart?.offset ?? 0)
      .task(id: query) {
        guard let query else { return }
        _ = try? await $chart.load(
          CardPreviewRequest(spec: query), scheduler: MainQueueScheduler())
      }
  }

  private var state: CardChart.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart, let spec else { return .loading }
    // The data drawn as the spec looks now.
    let period = CardPeriod(
      range: chart.range, offset: chart.offset,
      spec: chart.spec == query ? spec : chart.spec, data: chart.data)
    return .loaded(period, isUpdating: $chart.isLoading || chart.spec != query)
  }
}

/// A card at its range, on the period its page opens on (`CardSpec.openingOffset`).
struct CardPreviewRequest: FetchKeyRequest {
  let spec: CardSpec

  func fetch(_ db: Database) throws -> CardPeriod? {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let offset = try spec.openingOffset(in: spec.range, now: now, calendar: calendar, db)
    return try CardDataRequest(spec: spec, range: spec.range, offset: offset).fetch(db)
  }
}
