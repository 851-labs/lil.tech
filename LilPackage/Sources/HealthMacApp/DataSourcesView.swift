import Dependencies
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI

/// The apps and devices a type's data came from. Read-only: which source Health prefers is set
/// on the iPhone.
struct DataSourcesView: View {
  let type: HealthDataType
  @Dependency(\.defaultDatabase) private var database
  @State private var state = DataSourcesContent.State.loading

  var body: some View {
    DataSourcesContent(type: type, state: state)
      .task {
        do {
          let sources = try await database.read { [type] db in
            try HealthDatabase.sampleSources(of: type.id, db)
          }
          state = .loaded(apps: sources.apps, devices: sources.devices)
        } catch {
          state = .failed(error.localizedDescription)
        }
      }
  }
}

/// What Data Sources shows, however it got it.
struct DataSourcesContent: View {
  enum State {
    case loading
    case loaded(apps: [SampleSource], devices: [SampleDeviceSummary])
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
      case .loaded(let apps, _) where apps.isEmpty:
        ContentUnavailableView(
          "No Sources", systemImage: "app.dashed",
          description: Text("Apps and devices that record \(type.name) will appear here."))
      case .loaded(let apps, let devices):
        Form {
          Section {
            ForEach(apps) { app in
              LabeledContent(app.name, value: samples(app.count))
            }
          } header: {
            Text("Apps")
          } footer: {
            Text("Which source Health prefers is set in Health on your iPhone.")
          }
          if !devices.isEmpty {
            Section("Devices") {
              ForEach(devices) { summary in
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
