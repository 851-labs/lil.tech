#if os(macOS)
  import DependenciesTestSupport
  import Foundation
  import HealthDatabase
  import LilUI
  import SQLiteData
  import Testing

  // States of lil health for Mac, light and dark (851-2931), from fixed dates. Synthetic data
  // only. State catalogs (`Catalogs/`, 851-2949) add their tests to this suite, one per screen.

  /// The app Pixelbook shows these catalogs under (`CatalogManifest`, 851-2955).
  let pixelbookApp = "health-mac"

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance. Views that read the database, the date or the calendar get the catalogs'
  // (851-2950).
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      // Before the catalog database is built, which formats dates.
      fixTimeZoneAndLocale()
      fixAPIEnvironment()
      $0.defaultDatabase = catalogDatabase
      $0.date.now = previewNow
      $0.calendar = previewCalendar
      $0.timeZone = previewCalendar.timeZone
      $0.locale = previewCalendar.locale!
      // Loading states show their spinners in the image drawn at once (851-3086).
      $0.delayedProgressTiming = .immediate
    })
  struct MacSnapshotTests {
    init() {
      // Before any test builds its dates.
      prepareSnapshotEnvironment()
    }
  }

  /// The calendar whose time zone and locale `fixTimeZoneAndLocale()` makes the process's.
  let snapshotCalendar = previewCalendar
#endif
