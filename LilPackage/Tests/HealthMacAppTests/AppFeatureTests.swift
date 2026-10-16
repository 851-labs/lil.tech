import ComposableArchitecture
import Foundation
import HealthCatalog
import HealthMacApp
import LilAuth
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func followsTheSessionAndStartsAfreshAfterSigningOut() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
    }

    let task = await store.send(.task)
    continuation.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    await store.send(\.binding.selection, .category(.heart)) {
      $0.selection = .category(.heart)
    }
    await store.send(\.binding.searchText, "steps") {
      $0.searchText = "steps"
    }
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.selection = .summary
      $0.searchText = ""
    }
    await task.cancel()
  }

  @Test
  func searchFindsDataTypesByName() {
    var state = AppFeature.State(isSignedIn: true)
    #expect(state.searchResults.isEmpty)

    state.searchText = "  heart rate  "
    let names = state.searchResults.map(\.name)
    #expect(names.contains("Heart Rate"))
    #expect(names.allSatisfy { $0.localizedStandardContains("heart rate") })
    // In the sidebar's category order.
    let categories = state.searchResults.compactMap(\.category)
    #expect(
      categories
        == categories.sorted {
          HealthCategory.allCases.firstIndex(of: $0)! < HealthCategory.allCases.firstIndex(of: $1)!
        })

    state.searchText = "xylophone"
    #expect(state.searchResults.isEmpty)
  }
}
