import Foundation
import Observation
import Sparkle
public import SwiftUI

/// Checks for and installs app updates with Sparkle.
///
/// The feed URL (`SUFeedURL`) and the EdDSA public key (`SUPublicEDKey`) come from the app's
/// Info.plist.
@MainActor
@Observable
public final class AppUpdater {
  public private(set) var canCheckForUpdates = false

  @ObservationIgnored private let controller: SPUStandardUpdaterController
  @ObservationIgnored private var observation: NSKeyValueObservation?

  public init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      MainActor.assumeIsolated {
        self?.canCheckForUpdates = updater.canCheckForUpdates
      }
    }
  }

  public func checkForUpdatesButtonTapped() {
    controller.updater.checkForUpdates()
  }
}

/// Adds "Check for Updates…" to the app menu, after "About".
public struct CheckForUpdatesCommands: Commands {
  let updater: AppUpdater

  public init(updater: AppUpdater) {
    self.updater = updater
  }

  public var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        updater.checkForUpdatesButtonTapped()
      }
      .disabled(!updater.canCheckForUpdates)
    }
  }
}
