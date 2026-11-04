import HealthKit
import SwiftUI

/// The app that hosts the iPhone's HealthKit tests (`HealthKitPhoneTests`, 851-3199): it has the
/// HealthKit entitlement, so they can write synthetic samples into the simulator's HealthKit and
/// read them back. Launched with `-requestHealthAccess`, it asks to share and read the tests'
/// types, and `GrantHealthAccess`, a UI test, turns them all on in the sheet. Its copies, the
/// cards' conformance source apps (`ConformanceSourceApps`, 851-3201), launched with
/// `-writeConformance` or `-deleteConformance`, write or delete their source's part of the dataset
/// and exit (`ConformanceWriter`).
@main
struct HealthKitTestHostApp: App {
  var body: some Scene {
    WindowGroup {
      HostView()
    }
  }
}

private struct HostView: View {
  @State private var status = "Idle"

  var body: some View {
    Text(status)
      .accessibilityIdentifier("status")
      .task {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-writeConformance") || arguments.contains("-deleteConformance") {
          status = "Writing"
          exit(await ConformanceWriter.run(writing: arguments.contains("-writeConformance")))
        }
        guard arguments.contains("-requestHealthAccess") else { return }
        status = "Requesting"
        do {
          let types = TestHealthTypes.all
          try await HKHealthStore().requestAuthorization(toShare: types, read: types)
          status = "Requested"
        } catch {
          status = "Failed: \(error.localizedDescription)"
        }
      }
  }
}
