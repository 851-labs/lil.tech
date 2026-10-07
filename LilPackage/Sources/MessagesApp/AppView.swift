public import ComposableArchitecture
public import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Text(store.greeting)
      .font(.largeTitle)
      .frame(minWidth: 480, minHeight: 320)
      .onAppear { store.send(.onAppear) }
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
