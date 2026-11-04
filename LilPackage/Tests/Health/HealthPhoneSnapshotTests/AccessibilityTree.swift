#if os(iOS)
  import Darwin
  import SwiftUI
  import Testing
  import UIKit

  extension PhoneSnapshotTests {
    /// Shows `view` in the host app's window with accessibility on, as VoiceOver turns it on, and
    /// reads its accessibility elements with `read`, from its hosting view, after `change` (if
    /// any) has had it lay out again.
    func withAccessibility<Result>(
      of view: some View, after change: (() -> Void)? = nil,
      _ read: @MainActor (UIView) throws -> Result
    ) throws -> Result {
      let window = try #require(hostWindow())
      // SwiftUI makes its elements only while accessibility is on, as VoiceOver turns it on.
      let accessibility = try #require(Accessibility())
      let wasOn = accessibility.isEnabled()
      accessibility.setEnabled(true)
      defer { accessibility.setEnabled(wasOn) }
      let controller = UIHostingController(rootView: view)
      let host = window.rootViewController
      window.rootViewController = controller
      defer {
        window.rootViewController = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      controller.view.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      if let change {
        change()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      }
      return try read(try #require(controller.view))
    }
  }

  /// An element's children as VoiceOver finds them: its accessibility elements, or else a
  /// view's subviews.
  @MainActor
  func accessibilityChildren(of object: NSObject) -> [NSObject] {
    if let elements = object.accessibilityElements, !elements.isEmpty {
      return elements.compactMap { $0 as? NSObject }
    }
    let count = object.accessibilityElementCount()
    if count > 0, count != NSNotFound {
      return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
    }
    return (object as? UIView)?.subviews ?? []
  }

  /// The labels of every accessibility element under `object` that VoiceOver reads, depth first.
  @MainActor
  func accessibilityLabels(under object: NSObject) -> [String] {
    accessibilityChildren(of: object).flatMap { child in
      let label = child.isAccessibilityElement ? child.accessibilityLabel ?? "" : ""
      return (label.isEmpty ? [] : [label]) + accessibilityLabels(under: child)
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
