#if os(macOS)
  import AppKit
  import DependenciesTestSupport
  import Foundation
  import MessagesContacts
  import MessagesDatabase
  import SQLiteData
  import Testing

  // States of lil messages for Mac, light and dark (851-2968), from a fixed "now" and the
  // synthetic preview `chat.db`. Never the real `chat.db` (AGENTS.md, Privacy). State catalogs
  // (`Catalogs/`) add their tests to this suite, one per screen.

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance. Views that read the chat database, contacts, the date or the calendar get
  // the catalogs'.
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      // Before the catalog database is built, which formats dates.
      fixTimeZoneAndLocale()
      $0.chatDatabase = .constant(catalogChatDatabase)
      $0.contactNames = .constant(catalogContacts)
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
  /// `previewCalendar`'s time zone, lil health's (`HealthDatabase.previewNow`).
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

  /// The preview database's contact names, by address.
  let catalogContactNames = Dictionary(
    uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) })

  /// The address whose contact has a photo, `catalogContactPhoto`.
  let catalogContactPhotoAddress = "+14155550101"

  /// The preview database's contacts, one with a photo.
  let catalogContacts = ContactIndex(
    PreviewChatDatabase.contactNames.map {
      ContactIndex.Contact(
        name: $0.name,
        phoneNumbers: [$0.address],
        emails: [$0.address],
        thumbnailImageData: $0.address == catalogContactPhotoAddress ? catalogContactPhoto : nil
      )
    })

  /// A synthetic contact photo: a smiley on a gradient. Catalogs never use real contact photos.
  /// Drawn into a bitmap of a fixed size, in light, so it's the same on every Mac: drawn outside
  /// any view, it took the current drawing appearance, which followed the system's rather than the
  /// app's (the smiley turned into a filled disc in dark), and the screen's scale (851-2751).
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
      NSGradient(starting: .systemOrange, ending: .systemPink)?.draw(in: rect, angle: -90)
      let symbol = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
      symbol?.isTemplate = true
      if let symbol {
        let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
          symbol.draw(in: symbolRect)
          NSColor.white.set()
          symbolRect.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(
          in: NSRect(
            x: (rect.width - symbol.size.width) / 2,
            y: (rect.height - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
          )
        )
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
  }()
#endif
