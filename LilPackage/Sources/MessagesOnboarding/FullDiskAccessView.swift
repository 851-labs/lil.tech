import AppKit
public import ComposableArchitecture
public import SwiftUI

public struct FullDiskAccessView: View {
  let store: StoreOf<FullDiskAccessFeature>

  public init(store: StoreOf<FullDiskAccessFeature>) {
    self.store = store
  }

  public var body: some View {
    ContentUnavailableView {
      Label("Full Disk Access Required", systemImage: "lock.shield")
    } description: {
      Text(
        """
        lil messages reads your conversations from the Messages database on this Mac. \
        In System Settings, open Privacy & Security › Full Disk Access and turn on lil messages.
        """
      )
    } actions: {
      Button("Open System Settings") {
        store.send(.openSystemSettingsButtonTapped)
      }
      .buttonStyle(.borderedProminent)

      Button("Check Again") {
        store.send(.checkAgainButtonTapped)
      }
      .disabled(store.isChecking)
    }
    .frame(minWidth: 480, minHeight: 320)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      store.send(.appBecameActive)
    }
  }
}

#Preview("Default") {
  FullDiskAccessView(
    store: Store(initialState: FullDiskAccessFeature.State()) {
      FullDiskAccessFeature()
    }
  )
}

#Preview("Checking") {
  FullDiskAccessView(
    store: Store(initialState: FullDiskAccessFeature.State(isChecking: true)) {
      FullDiskAccessFeature()
    }
  )
}
