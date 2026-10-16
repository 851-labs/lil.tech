import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// The apps and devices a type's data came from, following the local database as sync changes
/// it. Read-only: which source Health prefers is set on the iPhone.
struct DataSourcesView: View {
  let type: HealthDataType
  @Fetch private var sources: SampleSources

  init(type: HealthDataType) {
    self.type = type
    _sources = Fetch(
      wrappedValue: SampleSources(apps: [], devices: []), SourcesRequest(typeID: type.id),
      scheduler: MainQueueScheduler())
  }

  var body: some View {
    DataSourcesContent(
      type: type,
      state: $sources.loadError.map { .failed($0.localizedDescription) }
        ?? ($sources.isLoading ? .loading : .loaded(sources)))
  }
}

struct SourcesRequest: FetchKeyRequest {
  let typeID: String

  func fetch(_ db: Database) throws -> SampleSources {
    try HealthDatabase.sampleSources(of: typeID, db)
  }
}

/// What Data Sources shows, however it got it.
struct DataSourcesContent: View {
  enum State {
    case loading
    case loaded(SampleSources)
    case failed(String)
  }

  let type: HealthDataType
  let state: State

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Sources", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let sources) where sources.apps.isEmpty:
        ContentUnavailableView(
          "No Sources", systemImage: "app.dashed",
          description: Text("Apps and devices that record \(type.name) will appear here."))
      case .loaded(let sources):
        Form {
          Section {
            ForEach(sources.apps) { app in
              LabeledContent(app.name, value: samples(app.count))
            }
          } header: {
            Text("Apps")
          } footer: {
            Text("Which source Health prefers is set in Health on your iPhone.")
          }
          if !sources.devices.isEmpty {
            Section("Devices") {
              ForEach(sources.devices) { summary in
                LabeledContent(
                  summary.device.name ?? summary.device.model ?? "Unknown Device",
                  value: samples(summary.count))
              }
            }
          }
        }
        .formStyle(.grouped)
      }
    }
    .navigationTitle("Data Sources")
  }

  private func samples(_ count: Int) -> String {
    count == 1 ? "1 sample" : "\(count.formatted()) samples"
  }
}
