import ComposableArchitecture
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// Summary: the pinned metrics' cards, with Edit to choose and order them. Follows the local
/// database as sync changes it.
struct SummaryView: View {
  @Bindable var store: StoreOf<SummaryFeature>
  @Fetch private var summaries: [MetricSummary]
  @Fetch private var highlights: [Highlight]

  init(store: StoreOf<SummaryFeature>) {
    self.store = store
    _highlights = Fetch(wrappedValue: [], HighlightsRequest(), scheduler: MainQueueScheduler())
    // With the pins' request from the start, so the first frame shows loading, not nothing.
    _summaries = Fetch(
      wrappedValue: [], PinnedSummaries(ids: store.orderedPins), scheduler: MainQueueScheduler())
  }

  var body: some View {
    let pins = store.orderedPins
    SummaryContent(
      pins: pins,
      state: $summaries.loadError.map { .failed($0.localizedDescription) }
        ?? ($summaries.isLoading && summaries.isEmpty ? .loading : .loaded(ordered(pins))),
      highlights: $highlights.loadError.map { .failed($0.localizedDescription) }
        ?? ($highlights.isLoading && highlights.isEmpty ? .loading : .loaded(highlights)),
      edit: { store.send(.editButtonTapped) },
      pin: { store.send(.pinButtonTapped($0)) }
    )
    .onChange(of: pins) { _, pins in
      Task {
        _ = try? await $summaries.load(PinnedSummaries(ids: pins), scheduler: MainQueueScheduler())
      }
    }
    .sheet(isPresented: $store.isEditing) {
      PinEditor(store: store)
    }
  }

  /// The fetched summaries in the pins' order, so a reorder shows at once, before the reload.
  private func ordered(_ pins: [String]) -> [MetricSummary] {
    let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return pins.compactMap { byID[$0] }
  }
}

/// Summary's highlights, as of when they're fetched.
struct HighlightsRequest: FetchKeyRequest {
  func fetch(_ db: Database) throws -> [Highlight] {
    try HealthDatabase.highlights(now: .now, calendar: .current, db)
  }
}

/// The pinned types' summaries, in pin order.
struct PinnedSummaries: FetchKeyRequest {
  let ids: [String]

  func fetch(_ db: Database) throws -> [MetricSummary] {
    try ids.compactMap(HealthCatalog.type(id:)).map {
      try HealthDatabase.metricSummary(of: $0, now: .now, calendar: .current, db)
    }
  }
}

/// What Summary shows, however it got it.
struct SummaryContent: View {
  enum State<Value> {
    case loading
    case loaded(Value)
    case failed(String)
  }

  let pins: [String]
  let state: State<[MetricSummary]>
  var highlights: State<[Highlight]> = .loaded([])
  let edit: () -> Void
  let pin: (String) -> Void
  var now = Date.now

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("Pinned")
            .font(.title2.bold())
          Spacer()
          if !pins.isEmpty {
            Button("Edit", action: edit)
          }
        }
        if pins.isEmpty {
          suggestions
        } else {
          switch state {
          case .loading:
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: 200)
          case .failed(let reason):
            ContentUnavailableView(
              "Couldn't Load Summary", systemImage: "exclamationmark.triangle",
              description: Text(reason))
          case .loaded(let summaries):
            ForEach(summaries) { summary in
              if let type = HealthCatalog.type(id: summary.id) {
                NavigationLink(value: summary.id) {
                  if summary.hasData {
                    MetricCard(
                      type: type, summary: summary, color: type.category?.color ?? .accentColor,
                      now: now)
                  } else {
                    NoDataCard(type: type)
                  }
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
        highlightsSection
          .padding(.top, 14)
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.groupedBackground)
    .navigationTitle("Summary")
  }

  @ViewBuilder private var highlightsSection: some View {
    Text("Highlights")
      .font(.title2.bold())
    switch highlights {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 120)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Highlights", systemImage: "exclamationmark.triangle",
        description: Text(reason))
    case .loaded(let highlights) where highlights.isEmpty:
      Text(
        "Highlights appear once there are a couple of weeks of steps, energy, heart or weight data to compare."
      )
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    case .loaded(let highlights):
      ForEach(highlights) { highlight in
        if let type = HealthCatalog.type(id: highlight.typeID) {
          NavigationLink(value: highlight.typeID) {
            HighlightCard(highlight: highlight, type: type)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  /// With nothing pinned: what Summary is for, and a few metrics to start with.
  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pin the metrics you check most, to see them here first.")
        .foregroundStyle(.secondary)
      ForEach(SummaryFeature.State.suggestions, id: \.self) { id in
        if let type = HealthCatalog.type(id: id) {
          HStack {
            HealthTypeLabel(type: type)
            Spacer()
            Button("Pin \(type.name)", systemImage: "plus.circle.fill") { pin(id) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(.green)
          }
        }
      }
      Button("Choose Metrics…", action: edit)
    }
    .padding(14)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }
}

/// A pinned metric without data yet.
struct NoDataCard: View {
  let type: HealthDataType

  var body: some View {
    HStack {
      HealthTypeLabel(type: type)
        .font(.headline)
      Spacer()
      Text("No Data")
        .foregroundStyle(.secondary)
      Image(systemName: "chevron.right")
        .font(.caption.bold())
        .foregroundStyle(.tertiary)
    }
    .padding(14)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    .contentShape(RoundedRectangle(cornerRadius: 12))
  }
}

/// Edit: the pins in order, to move or remove, and the other metrics to pin.
struct PinEditor: View {
  @Bindable var store: StoreOf<SummaryFeature>

  var body: some View {
    NavigationStack {
      List {
        Section("Pinned") {
          if store.orderedPins.isEmpty {
            Text("Nothing pinned yet")
              .foregroundStyle(.secondary)
          }
          ForEach(store.orderedPins, id: \.self) { id in
            row(id, pinned: true)
          }
          .onMove { store.send(.pinsMoved($0, $1)) }
        }
        Section("Metrics") {
          ForEach(store.unpinned) { type in
            row(type.id, pinned: false)
          }
        }
      }
      .searchable(text: $store.search, prompt: "Search Metrics")
      .navigationTitle("Edit Summary")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.send(.doneButtonTapped) }
        }
      }
    }
    .frame(minWidth: 420, minHeight: 520)
  }

  private func row(_ id: String, pinned: Bool) -> some View {
    let type = HealthCatalog.type(id: id)
    return HStack {
      if let type {
        HealthTypeLabel(type: type)
      } else {
        Text(id)
      }
      Spacer()
      if pinned {
        Button("Unpin \(type?.name ?? id)", systemImage: "minus.circle.fill") {
          store.send(.unpinButtonTapped(id))
        }
        .foregroundStyle(.red)
        .labelStyle(.iconOnly)
      } else {
        Button("Pin \(type?.name ?? id)", systemImage: "plus.circle.fill") {
          store.send(.pinButtonTapped(id))
        }
        .foregroundStyle(.green)
        .labelStyle(.iconOnly)
      }
    }
    .buttonStyle(.borderless)
  }
}
