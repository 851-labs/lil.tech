#if os(macOS)
  import Foundation
  import Testing

  // Shared with MessagesSnapshotTests, which links this file (851-2968). Each target says which
  // calendar its catalogs use, `snapshotCalendar`.

  /// Makes `snapshotCalendar`'s time zone and locale (`en_US`) the process's, once (851-2950). Text
  /// a view formats itself (`formatted()`) uses the process's locale, not the view's
  /// environment's, so it would otherwise follow the Mac's. Call it before anything reads
  /// `Locale.current`, which reads the settings once: a catalog suite's dependencies trait calls it
  /// first, since the trait runs before the suite's `init`.
  ///
  /// It also turns off the Mac's "Allow wallpaper tinting in windows" (`AppleReduceDesktopTinting`),
  /// so no image depends on that setting or the desktop picture (851-3172). Offscreen, windows
  /// never take the tint, but views Swift Charts draws do: a sparkline's hollow latest dot, filled
  /// with `.background.secondary`, came out 16 levels lighter in dark mode (gray 58, not 42) with
  /// the setting on. AppKit reads it once, so it's set here, before anything draws.
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
    NSTimeZone.default = snapshotCalendar.timeZone
    let locale = snapshotCalendar.locale!
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
      // Not the locale's: no wallpaper tinting, above.
      "AppleReduceDesktopTinting": true,
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
