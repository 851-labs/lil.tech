import AppKit
import ComposableArchitecture
import SwiftUI

/// The message composer, an AppKit leaf view per `docs/DECISIONS.md`. Return sends and
/// Shift-Return inserts a newline.
struct ComposerView: NSViewRepresentable {
  let store: StoreOf<MessageThreadFeature>

  func makeNSView(context: Context) -> ComposerTextView {
    ComposerTextView(store: store)
  }

  func updateNSView(_ view: ComposerTextView, context: Context) {}
}

final class ComposerTextView: NSView, NSTextViewDelegate {
  private let store: StoreOf<MessageThreadFeature>
  private let scrollView = NSScrollView()
  private let textView = NSTextView()

  init(store: StoreOf<MessageThreadFeature>) {
    self.store = store
    super.init(frame: .zero)

    textView.delegate = self
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .preferredFont(forTextStyle: .body)
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.setAccessibilityLabel("Message")

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    observe { [weak self] in
      guard let self else { return }
      let draft = store.draft
      if textView.string != draft {
        textView.string = draft
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func textDidChange(_ notification: Notification) {
    store.send(.draftChanged(textView.string))
  }

  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
      textView.insertNewlineIgnoringFieldEditor(nil)
      return true
    }
    store.send(.returnKeyPressed)
    return true
  }
}
