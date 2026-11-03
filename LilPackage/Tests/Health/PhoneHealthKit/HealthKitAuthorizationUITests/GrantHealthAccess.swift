import XCTest

/// Turns on HealthKit access for the tests' host (`HealthKitTestHost`) in a fresh simulator, as a
/// person would in the sheet: `simctl privacy` can't grant Health. `scripts/test-iphone-healthkit`
/// runs it before `HealthKitPhoneTests` (851-3199).
final class GrantHealthAccess: XCTestCase {
  @MainActor
  func testGrantHealthAccess() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-requestHealthAccess"]
    let status = app.staticTexts["status"]
    // Health's own process draws the sheet (iOS 27). Already granted, there's none, and the host
    // says so. In a simulator just booted, the first request can wait minutes for a sheet that
    // never comes: then the host asks again.
    let sheet = XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyService")
    let topics = sheet.navigationBars["Health Access"]
    var shown = false
    for attempt in 1...3 {
      app.launch()
      XCTAssertTrue(status.waitForExistence(timeout: 30))
      // The host starts idle, then asks: the sheet comes, or the request ends without one.
      let deadline = Date.now.addingTimeInterval(60)
      while Date.now < deadline, !shown, !isFinished(status.label) {
        shown = topics.waitForExistence(timeout: 1)
      }
      if shown || isFinished(status.label) || attempt == 3 { break }
      app.terminate()
    }
    if shown {
      // The types, a long list whose button ("Continue") is only there once scrolled to.
      turnOnEverything(in: sheet)
      let next = sheet.buttons["UIA.Health.Allow.Button"]
      for _ in 0..<15 where !(next.exists && next.isHittable) {
        sheet.tables.firstMatch.swipeUp()
      }
      XCTAssertTrue(next.isHittable, "No button after the types.")
      next.tap()
      // How much history: all of it, since the tests write samples from months ago.
      let history = sheet.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH 'All Recorded Data'")).firstMatch
      if history.waitForExistence(timeout: 10) {
        history.tap()
        let allow = sheet.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "No Allow button.")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: allow)
        wait(for: [enabled], timeout: 10)
        allow.tap()
      }
      screenshot("After allowing")
    }
    let finished = NSPredicate(format: "label == 'Requested' OR label BEGINSWITH 'Failed'")
    wait(for: [expectation(for: finished, evaluatedWith: status)], timeout: 30)
    XCTAssertEqual(status.label, "Requested")
    app.terminate()
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
