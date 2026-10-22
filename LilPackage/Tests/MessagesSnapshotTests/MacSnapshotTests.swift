#if os(macOS)
  import AppKit
  import DependenciesTestSupport
  import Foundation
  import MessagesDatabase
  import SQLiteData
  import Testing

  // States of lil messages for Mac, light and dark (851-2968), from a fixed "now" and the
  // synthetic `chat.db`. Never the real `chat.db` (AGENTS.md, Privacy). State catalogs
  // (`Catalogs/`) add their tests to this suite, one per screen.

  /// The app Pixelbook shows these catalogs under (`CatalogManifest`, 851-2955).
  let pixelbookApp = "messages-mac"

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance. Views that read the date or the calendar get the catalogs'. Stores have no
  // reducer, so nothing reads the chat database or contacts: states get them in their state.
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      // Before the catalog database is built, which formats dates.
      fixTimeZoneAndLocale()
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

  /// The fixed "now" of lil messages' catalogs: Tuesday, August 13, 2024, 3 PM in
  /// `previewCalendar`'s time zone, lil health's (`HealthDatabase.previewNow`), copied since this
  /// target imports none of lil health's modules.
  let previewNow = Date(timeIntervalSince1970: 1_723_586_400)

  /// Gregorian, in Los Angeles, with `en_US`'s formats, as lil health's catalogs.
  let previewCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }()

  /// The calendar whose time zone and locale `fixTimeZoneAndLocale()` makes the process's.
  let snapshotCalendar = previewCalendar

  /// The synthetic `chat.db` at `previewNow`, built once per process. States read it, never write
  /// to it.
  let catalogChatDatabase = try! makePreviewChatDatabase(now: previewNow, calendar: previewCalendar)

  /// The synthetic `chat.db`'s contact names, by address.
  let catalogContactNames = Dictionary(
    uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) })

  /// The address whose contact has a photo, `catalogContactPhoto`.
  let catalogContactPhotoAddress = "+14155550101"

  /// A synthetic contact photo: a smiley on a gradient. Catalogs never use real contact photos.
  /// Drawn into a bitmap of a fixed size, in light, so it's the same on every Mac: drawn outside
  /// any view, it took the current drawing appearance, which followed the system's rather than the
  /// app's, and the screen's scale (851-2751). The face is paths, not an SF Symbol, which macOS
  /// 27.0 and 27.0.1 draw differently (851-3007).
  let catalogContactPhoto: Data = {
    let size = NSSize(width: 120, height: 120)
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
      let rect = NSRect(origin: .zero, size: size)
      NSGradient(
        starting: NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1),
        ending: NSColor(srgbRed: 1, green: 0.18, blue: 0.33, alpha: 1)
      )?.draw(in: rect, angle: -90)
      NSColor.white.set()
      let face = NSBezierPath(ovalIn: rect.insetBy(dx: 30, dy: 30))
      face.lineWidth = 5
      face.stroke()
      NSBezierPath(ovalIn: NSRect(x: 47, y: 64, width: 8, height: 11)).fill()
      NSBezierPath(ovalIn: NSRect(x: 65, y: 64, width: 8, height: 11)).fill()
      let smile = NSBezierPath()
      smile.appendArc(
        withCenter: NSPoint(x: 60, y: 60), radius: 18, startAngle: 210, endAngle: 330)
      smile.lineWidth = 5
      smile.lineCapStyle = .round
      smile.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
  }()
#endif
