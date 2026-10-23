#if os(iOS)
  import Dependencies
  import DependenciesTestSupport
  import Foundation
  import LilUI
  import Testing

  // State catalogs of lil health for iPhone (851-2953), rendered in the simulator by an app test
  // host so Liquid Glass draws: `scripts/snapshot --iphone`. Each catalog (`Catalogs/`) adds its
  // test to this suite. Synthetic data only.

  /// The catalogs' fixed "now", the same as the Mac's (`HealthDatabase`'s `previewNow`, which this
  /// target doesn't build): Tuesday, August 13, 2024, 3 PM in Los Angeles.
  let previewNow = Date(timeIntervalSince1970: 1_723_586_400)

  // Serialized: every snapshot draws in the host app's one window. Views that read the date get
  // the catalogs'.
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      $0.date.now = previewNow
      // Loading states show their spinners in the image drawn at once (851-3086).
      $0.delayedProgressTiming = .immediate
    })
  struct PhoneSnapshotTests {}
#endif
