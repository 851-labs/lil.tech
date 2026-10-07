import ComposableArchitecture
import MessagesApp
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func onAppear() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.onAppear)
  }
}
