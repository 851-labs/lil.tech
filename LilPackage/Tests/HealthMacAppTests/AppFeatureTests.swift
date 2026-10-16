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
    // Spaces alone aren't a search.
    state.searchText = "   "
    #expect(state.query.isEmpty)
  }

  @Test
  func searchCoversEveryVersionButNotCharacteristics() {
    let state = AppFeature.State(isSignedIn: true, searchText: "menopause")
    // Added in iOS 27, and synced from iPhones that have it.
    #expect(!state.searchResults.isEmpty)
    #expect(AppFeature.State(isSignedIn: true, searchText: "blood type").searchResults.isEmpty)
  }

  @Test
  func clearingTheSearchSelectsTheFoundTypesCategory() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
        searchText: "heart")
    ) {
      AppFeature()
    }
    await store.send(\.binding.searchText, "") {
      $0.searchText = ""
      $0.selection = .category(.heart)
    }
  }
}
