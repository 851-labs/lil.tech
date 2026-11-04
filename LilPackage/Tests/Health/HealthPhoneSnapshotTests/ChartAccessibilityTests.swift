#if os(iOS)
  import Darwin
  import SwiftUI
  import Testing
  import UIKit

  // The iPhone's side of the Mac's `ChartAccessibilityTests` (851-4042): a card's chart, in
  // `chartAccessibility`, is a container named for what it charts and when, holding its points,
  // and an empty one is one element, "No data for …". Read from the accessibility elements UIKit
  // gives VoiceOver, with the page in the host app's window.

  extension PhoneSnapshotTests {
    @Test func chartAccessibility() throws {
      #expect(try chartLabels("Steps, week") == ["Steps, Aug 11 – 17, 2024": 3])
      #expect(try chartLabels("Steps, no data") == ["No data for Aug 11 – 17, 2024": 0])
    }

    /// What VoiceOver reads of a Card Detail state's chart: the chart's label, or an empty
    /// period's, with its children (the points).
    private func chartLabels(_ name: String) throws -> [String: Int] {
      let state = try #require(cardDetailCatalog.states.first { $0.name == name })
      let window = try #require(hostWindow())
      // SwiftUI makes its elements only while accessibility is on, as VoiceOver turns it on.
      let accessibility = try #require(Accessibility())
      let wasOn = accessibility.isEnabled()
      accessibility.setEnabled(true)
      defer { accessibility.setEnabled(wasOn) }
      // As `draw` shows it, in the suite's locale: these states have none of their own.
      let controller = UIHostingController(
        rootView: state.view().environment(\.locale, Locale(identifier: "en_US")))
      let host = window.rootViewController
      window.rootViewController = controller
      defer {
        window.rootViewController = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      controller.view.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      var labels: [String: Int] = [:]
      func visit(_ object: NSObject) {
        let children = accessibilityChildren(of: object)
        let label = (object.accessibilityLabel ?? "").replacingOccurrences(
          of: "\u{2009}", with: " ")
        let isChart =
          !children.isEmpty
          && children.allSatisfy { ($0.accessibilityLabel ?? "").contains(" to ") }
        if isChart || label.hasPrefix("No data for ") || label.hasPrefix("Not present in ") {
          labels[label, default: 0] += children.count
        }
        children.forEach(visit)
      }
      visit(try #require(controller.view))
      return labels
    }

    /// An element's children as VoiceOver finds them: its accessibility elements, or else a
    /// view's subviews.
    private func accessibilityChildren(of object: NSObject) -> [NSObject] {
      if let elements = object.accessibilityElements, !elements.isEmpty {
        return elements.compactMap { $0 as? NSObject }
      }
      let count = object.accessibilityElementCount()
      if count > 0, count != NSNotFound {
        return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
      }
      return (object as? UIView)?.subviews ?? []
    }
  }

  /// libAccessibility's switch for the app's accessibility, which VoiceOver and XCUITest turn on.
  private struct Accessibility {
    let isEnabled: @convention(c) () -> Bool
    let setEnabled: @convention(c) (Bool) -> Void

    init?() {
      guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
        let get = dlsym(library, "_AXSApplicationAccessibilityEnabled"),
        let set = dlsym(library, "_AXSApplicationAccessibilitySetEnabled")
      else { return nil }
      isEnabled = unsafeBitCast(get, to: (@convention(c) () -> Bool).self)
      setEnabled = unsafeBitCast(set, to: (@convention(c) (Bool) -> Void).self)
    }
  }
#endif
