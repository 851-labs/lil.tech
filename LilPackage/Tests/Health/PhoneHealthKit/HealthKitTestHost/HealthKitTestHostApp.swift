import HealthKit
import SwiftUI

/// The app that hosts the iPhone's HealthKit tests (`HealthKitPhoneTests`, 851-3199): it has the
/// HealthKit entitlement, so they can write synthetic samples into the simulator's HealthKit and
/// read them back. Launched with `-requestHealthAccess`, it asks to share and read the tests'
/// types, and `GrantHealthAccess`, a UI test, turns them all on in the sheet.
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
        guard ProcessInfo.processInfo.arguments.contains("-requestHealthAccess") else { return }
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
