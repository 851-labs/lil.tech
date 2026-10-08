import AppKit
import Testing

@testable import MessageThreadFeature

@MainActor
struct MessageTextViewTests {
  @Test
  func sizesToItsText() {
    let textView = MessageTextView()
    textView.configure(text: "Hello", links: [], textColor: .labelColor, linkColor: .linkColor)
    let size = textView.intrinsicContentSize
    #expect(size.width > 10)
    #expect(size.height > 10)
  }

  @Test
  func wrapsAtPreferredMaxLayoutWidth() {
    let textView = MessageTextView()
    let text = String(repeating: "word ", count: 40)
    textView.configure(text: text, links: [], textColor: .labelColor, linkColor: .linkColor)
    let oneLine = textView.intrinsicContentSize
    textView.preferredMaxLayoutWidth = 120
    let wrapped = textView.intrinsicContentSize
    #expect(wrapped.width <= 120)
    #expect(wrapped.height > oneLine.height * 2)
  }
}
