#if os(macOS)
  import Foundation
  import HealthDatabase
  import Testing

  /// Makes `previewCalendar`'s time zone and locale (`en_US`) the process's (851-2950). Text a
  /// view formats itself (`formatted()`) uses the process's locale, not the view's environment's,
  /// so it would otherwise follow the Mac's. The process's argument domain overrides the Mac's
  /// settings, including those that change a locale's formats (24-hour time, the first weekday,
  /// units: `en_US`'s own here), as `-AppleLocale` on the command line would. `Locale.current`
  /// reads them once, so this fails a test if anything read it first.
  @MainActor
  func fixTimeZoneAndLocale() {
    NSTimeZone.default = previewCalendar.timeZone
    let locale = previewCalendar.locale!
    UserDefaults.standard.setVolatileDomain(
      [
        "AppleLocale": locale.identifier,
        "AppleLanguages": [locale.identifier(.bcp47)],
        "AppleICUForce12HourTime": false,
        "AppleICUForce24HourTime": false,
        "AppleFirstWeekday": [String: Int](),
        "AppleMinimumDaysInFirstWeek": [String: Int](),
        "AppleICUDateFormatStrings": [String: String](),
        "AppleICUTimeFormatStrings": [String: String](),
        "AppleICUNumberSymbols": [String: String](),
        "AppleMeasurementUnits": "Inches",
        "AppleMetricUnits": false,
        "AppleTemperatureUnit": "Fahrenheit",
      ],
      forName: UserDefaults.argumentDomain)
    if Locale.current.identifier != locale.identifier {
      Issue.record(
        """
        The locale is \(Locale.current.identifier), not \(locale.identifier): something read it \
        before the snapshot environment was prepared.
        """)
    }
  }
#endif
