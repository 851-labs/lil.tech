#if os(iOS)
  import Darwin
  import SwiftUI
  import Testing
  import UIKit

  extension PhoneSnapshotTests {
    /// Shows `view` in the host app's window with accessibility on, as VoiceOver turns it on, and
    /// reads its accessibility elements with `read`, from its hosting view, once `isReady` says
    /// what it read is all there (or 5 seconds have passed): UIKit makes them a moment after the
    /// view lays out, longer on a busy Mac.
    func withAccessibility<Result>(
      of view: some View, until isReady: (Result) -> Bool = { _ in true },
      _ read: @MainActor (UIView) throws -> Result
    ) throws -> Result {
      try hosting(view) { root in try poll(until: isReady) { try read(root) } }
    }

    /// Like `withAccessibility(of:until:_:)`, read again after `change`, once what it reads has
    /// changed: UIKit's elements follow the view a moment after it changes.
    func withAccessibility<Result: Equatable>(
      of view: some View, until isReady: (Result) -> Bool, after change: () -> Void,
      _ read: @MainActor (UIView) throws -> Result
    ) throws -> Result {
      try hosting(view) { root in
        let before = try poll(until: isReady) { try read(root) }
        change()
        return try poll(until: { $0 != before }) { try read(root) }
      }
    }

    /// `read`'s result once `isReady` says so, or after 5 seconds.
    private func poll<Result>(
      until isReady: (Result) -> Bool, _ read: @MainActor () throws -> Result
    ) throws -> Result {
      let deadline = Date().addingTimeInterval(5)
      var result = try read()
      while !isReady(result), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        result = try read()
      }
      return result
    }

    private func hosting<Result>(
      _ view: some View, _ body: @MainActor (UIView) throws -> Result
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
      return try body(try #require(controller.view))
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
