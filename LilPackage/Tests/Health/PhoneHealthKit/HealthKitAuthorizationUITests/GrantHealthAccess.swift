import XCTest

/// Turns on HealthKit access for the tests' host (`HealthKitTestHost`) in a fresh simulator, as a
/// person would in the sheet: `simctl privacy` can't grant Health. `scripts/test-iphone-healthkit`
/// runs it before `HealthKitPhoneTests` (851-3199). Then for each of the cards' conformance source
/// apps (`ConformanceSourceApps`, 851-3201) the script installed, whose bundle IDs it passes in
/// `LIL_HEALTHKIT_SOURCE_APPS`, separated by spaces.
final class GrantHealthAccess: XCTestCase {
  @MainActor
  func testGrantHealthAccess() throws {
    grant(XCUIApplication())
    let sources = ProcessInfo.processInfo.environment["LIL_HEALTHKIT_SOURCE_APPS"] ?? ""
    for bundleID in sources.split(separator: " ") {
      grant(XCUIApplication(bundleIdentifier: String(bundleID)))
    }
  }

  @MainActor
  private func grant(_ app: XCUIApplication) {
    app.launchArguments = ["-requestHealthAccess"]
    let status = app.staticTexts["status"]
    // Health's own process draws the sheet (iOS 27). Already granted, there's none, and the host
    // says so. In a simulator just booted, the first request can wait minutes for a sheet that
    // never comes, or time out after it comes: then the host asks again.
    let sheet = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
    let topics = sheet.navigationBars["Health Access"]
    for attempt in 1...4 {
      app.launch()
      // A slow launch is tried again, like a request that times out.
      guard status.waitForExistence(timeout: 30) else {
        app.terminate()
        if attempt == 4 { XCTFail("\(app.description) never showed its status.") }
        continue
      }
      // The host starts idle, then asks: the sheet comes, or the request ends without one.
      var shown = false
      let deadline = Date.now.addingTimeInterval(60)
      while Date.now < deadline, !shown, !isFinished(status.label) {
        shown = topics.waitForExistence(timeout: 1)
      }
      if shown {
        allowEverything(in: sheet)
      }
      let finished = NSPredicate(format: "label == 'Requested' OR label BEGINSWITH 'Failed'")
      _ = XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: finished, object: status)], timeout: 30)
      let label = status.label
      app.terminate()
      if label == "Requested" { return }
      if attempt == 4 {
        XCTFail("\(app.description): \(label)")
      }
    }
  }

  /// Turns every type on, then allows all recorded data.
  @MainActor
  private func allowEverything(in sheet: XCUIApplication) {
    // The types, a long list whose button ("Continue") is only there once scrolled to.
    turnOnEverything(in: sheet)
    let next = sheet.buttons["UIA.Health.Allow.Button"]
    for _ in 0..<15 where !(next.exists && next.isHittable) {
      sheet.tables.firstMatch.swipeUp()
    }
    guard next.isHittable else {
      screenshot("No button after the types")
      return
    }
    next.tap()
    // How much history: all of it, since the tests write samples from months ago.
    let history = sheet.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH 'All Recorded Data'")).firstMatch
    if history.waitForExistence(timeout: 10) {
      history.tap()
      let allow = sheet.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
      guard allow.waitForExistence(timeout: 10) else {
        screenshot("No Allow button")
        return
      }
      let enabled = NSPredicate(format: "enabled == true")
      _ = XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: enabled, object: allow)], timeout: 10)
      allow.tap()
    }
    screenshot("After allowing")
  }

  /// Whether the host's request ended, granted or not.
  private func isFinished(_ label: String) -> Bool {
    label == "Requested" || label.hasPrefix("Failed")
  }

  /// The screen, kept in the result bundle when the test fails, to see what the sheet showed.
  @MainActor
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    add(attachment)
  }

  /// "Select All N Topics" where the page has it, else each switch that's off, from the top of
  /// the list to its end.
  @MainActor
  private func turnOnEverything(in sheet: XCUIApplication) {
    let selectAll = sheet.cells["UIA.Health.AuthSheet.AllCategoryButton"]
    if selectAll.exists {
      selectAll.tap()
      return
    }
    let off = sheet.switches.matching(NSPredicate(format: "value == '0'"))
    for _ in 0..<12 {
      // Each tap turns one on, so it's no longer among them.
      var taps = 0
      while taps < 50, let next = off.allElementsBoundByIndex.first(where: \.isHittable) {
        next.tap()
        taps += 1
      }
      sheet.tables.firstMatch.swipeUp()
    }
  }
}
