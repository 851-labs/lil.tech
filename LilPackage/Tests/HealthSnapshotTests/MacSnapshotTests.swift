#if os(macOS)
  import DependenciesTestSupport
  import Foundation
  import HealthDatabase
  import SQLiteData
  import Testing

  // States of lil health for Mac, light and dark (851-2931), from fixed dates. Synthetic data
  // only. State catalogs (`Catalogs/`, 851-2949) add their tests to this suite, one per screen.

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance. Views that read the database, the date or the calendar get the catalogs'
  // (851-2950).
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      // Before the catalog database is built, which formats dates.
      fixTimeZoneAndLocale()
      $0.defaultDatabase = catalogDatabase
      $0.date.now = previewNow
      $0.calendar = previewCalendar
      $0.timeZone = previewCalendar.timeZone
      $0.locale = previewCalendar.locale!
    })
  struct MacSnapshotTests {
    init() {
      // Before any test builds its dates.
      prepareSnapshotEnvironment()
    }
  }
#endif
