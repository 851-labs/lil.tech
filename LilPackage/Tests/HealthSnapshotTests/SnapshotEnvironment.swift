#if os(macOS)
  import Foundation
  import HealthDatabase
  import Testing

  /// Makes `previewCalendar`'s time zone and locale (`en_US`) the process's, once (851-2950). Text
  /// a view formats itself (`formatted()`) uses the process's locale, not the view's
  /// environment's, so it would otherwise follow the Mac's. Call it before anything reads
  /// `Locale.current`, which reads the settings once: a catalog suite's dependencies trait calls it
  /// first, since the trait runs before the suite's `init`.
  func fixTimeZoneAndLocale() {
    _ = timeZoneAndLocale
  }

  /// Drops `LIL_API_URL` from the process's environment, once, so views that show the API's
  /// URLs (Settings' MCP server URL) show staging's, as a Debug build does, whichever deployment
  /// the shell points at. Call it before a view reads `APIEnvironment.current()`, which some keep.
  func fixAPIEnvironment() {
    _ = apiEnvironment
  }

  private let apiEnvironment: Void = {
    unsetenv("LIL_API_URL")
  }()

  private let timeZoneAndLocale: Void = {
    NSTimeZone.default = previewCalendar.timeZone
    let locale = previewCalendar.locale!
    // The argument domain overrides the Mac's settings, as `-AppleLocale` on the command line
    // would, including those that change a locale's formats (12- or 24-hour time, the first
    // weekday, units), here set to the locale's own. Merged, so launch arguments still apply.
    let isUS = locale.measurementSystem == .us
    let overrides: [String: Any] = [
      "AppleLocale": locale.identifier,
      "AppleLanguages": [locale.identifier(.bcp47)],
      "AppleICUForce12HourTime": false,
      "AppleICUForce24HourTime": false,
      "AppleFirstWeekday": [String: Int](),
      "AppleMinimumDaysInFirstWeek": [String: Int](),
      "AppleICUDateFormatStrings": [String: String](),
      "AppleICUTimeFormatStrings": [String: String](),
      "AppleICUNumberSymbols": [String: String](),
      "AppleMeasurementUnits": isUS ? "Inches" : "Centimeters",
      "AppleMetricUnits": !isUS,
      "AppleTemperatureUnit": isUS ? "Fahrenheit" : "Celsius",
    ]
    let defaults = UserDefaults.standard
    defaults.setVolatileDomain(
      defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        .merging(overrides) { _, override in override },
      forName: UserDefaults.argumentDomain)
    // A locale read before this keeps the Mac's settings, whose identifier may still match.
    let current = Locale.current
    if current.identifier != locale.identifier || current.hourCycle != locale.hourCycle
      || current.firstDayOfWeek != locale.firstDayOfWeek
      || current.measurementSystem != locale.measurementSystem
    {
      Issue.record(
        """
        The locale is the Mac's (\(current.identifier), \(current.hourCycle), weeks from \
        \(current.firstDayOfWeek), \(current.measurementSystem)), not \(locale.identifier)'s: \
        something read it before fixTimeZoneAndLocale().
        """)
    }
  }()
#endif
