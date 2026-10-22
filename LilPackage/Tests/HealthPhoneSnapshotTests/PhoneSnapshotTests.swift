#if os(iOS)
  import ComposableArchitecture
  import Foundation
  import HealthCatalog
  @testable import HealthPhoneApp
  import HealthUpload
  import SnapshotTesting
  import SwiftUI
  import Testing
  import UIKit

  // Preview states of lil health for iPhone, rendered by swift-snapshot-testing in the iPhone
  // simulator (851-2931). Synthetic data only.

  @MainActor
  @Suite(.snapshots(record: .missing))
  struct PhoneSnapshotTests {
    // SyncStatusViewPreviews.swift, "Up to date".
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func syncStatusUpToDate(style: UIUserInterfaceStyle) {
      let clock = ContinuousClock()
      let start = clock.now
      let types = HealthBackfillType.all(availableOn: .ios(26)).map(\.id)
      let byType = Dictionary(
        uniqueKeysWithValues: types.enumerated().map { index, id in
          (id, HealthBackfill.TypeProgress(isDone: true, uploadedRecords: 1_200 + index * 37))
        })
      let progress = HealthBackfill.Progress(
        finishedTypes: types.count, totalTypes: types.count,
        uploadedRecords: byType.values.map(\.uploadedRecords).reduce(0, +), isRunning: false,
        failure: nil, isOffline: false, isStorageFull: false, types: byType,
        lastUploadAt: Date(timeIntervalSinceNow: -300))
      let state = SyncStatusFeature.State(progress: progress)
      state.$consentedPolicyVersion.withLock { $0 = HealthConsentClient.policyVersion }
      let view = SyncStatusView(
        store: Store(initialState: state) {
          EmptyReducer<SyncStatusFeature.State, SyncStatusFeature.Action>()
            .ifLet(\.$alert, action: \.alert)
        })
      let suffix = style == .dark ? "dark" : "light"
      assertSnapshot(
        of: view,
        as: .image(
          drawHierarchyInKeyWindow: false, layout: .device(config: .iPhone18Pro),
          traits: UITraitCollection(userInterfaceStyle: style)),
        named: "sync-status-up-to-date-\(suffix)", testName: "iphone")
      print("snapshot sync-status-up-to-date-\(suffix): \(clock.now - start)")
    }
  }

  extension ViewImageConfig {
    /// iPhone 17 Pro and 18 Pro: 402 × 874 points at 3x.
    static let iPhone18Pro = ViewImageConfig(
      safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
      size: CGSize(width: 402, height: 874),
      traits: UITraitCollection { traits in
        traits.displayScale = 3
        traits.userInterfaceIdiom = .phone
        traits.horizontalSizeClass = .compact
        traits.verticalSizeClass = .regular
        traits.forceTouchCapability = .available
        traits.layoutDirection = .leftToRight
        traits.preferredContentSizeCategory = .medium
      })
  }
#endif
