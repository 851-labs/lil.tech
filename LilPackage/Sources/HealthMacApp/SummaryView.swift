import ComposableArchitecture
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// Summary: the pinned metrics' cards, with Edit to choose and order them. Follows the local
/// database as sync changes it.
struct SummaryView: View {
  @Bindable var store: StoreOf<SummaryFeature>
  @Fetch private var summaries: [MetricSummary] = []

  var body: some View {
    SummaryContent(
      pins: store.pins,
      state: $summaries.loadError.map { .failed($0.localizedDescription) }
        ?? ($summaries.isLoading ? .loading : .loaded(summaries)),
      edit: { store.send(.editButtonTapped) },
      pin: { store.send(.pinButtonTapped($0)) }
    )
    .task(id: store.pins) {
      _ = try? await $summaries.load(
        PinnedSummaries(ids: store.pins), scheduler: MainQueueScheduler())
    }
    .sheet(isPresented: $store.isEditing) {
      PinEditor(store: store)
    }
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
  enum State {
    case loading
    case loaded([MetricSummary])
    case failed(String)
  }

  let pins: [String]
  let state: State
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
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color.groupedBackground)
    .navigationTitle("Summary")
  }

  /// With nothing pinned: what Summary is for, and a few metrics to start with.
  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pin the metrics you check most, to see them here first.")
        .foregroundStyle(.secondary)
      ForEach(SummaryFeature.State.suggestions, id: \.self) { id in
        if let type = HealthCatalog.type(id: id) {
          HStack {
            Label(type.name, systemImage: type.category?.symbolName ?? "circle")
              .foregroundStyle(type.category?.color ?? .accentColor)
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
      Label(type.name, systemImage: type.category?.symbolName ?? "circle")
        .font(.headline)
        .foregroundStyle(type.category?.color ?? .accentColor)
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
          if store.pins.isEmpty {
            Text("Nothing pinned yet")
              .foregroundStyle(.secondary)
          }
          ForEach(store.pins, id: \.self) { id in
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
      Label(type?.name ?? id, systemImage: type?.category?.symbolName ?? "circle")
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
