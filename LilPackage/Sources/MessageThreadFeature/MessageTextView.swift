import AppKit

/// A link found in a message body: a URL, or a phone number turned into a `tel:` URL.
struct MessageLink: Equatable {
  var range: NSRange
  var url: URL

  /// Finds URLs and phone numbers in `text`, like Messages' data detectors.
  nonisolated static func detect(in text: String) -> [MessageLink] {
    guard
      !text.isEmpty,
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
          | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
      )
    else { return [] }
    let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
    return matches.compactMap { match in
      switch match.resultType {
      case .link:
        return match.url.map { MessageLink(range: match.range, url: $0) }
      case .phoneNumber:
        guard let number = match.phoneNumber else { return nil }
        let dialable = number.filter { $0.isNumber || $0 == "+" }
        return URL(string: "tel:\(dialable)").map { MessageLink(range: match.range, url: $0) }
      default:
        return nil
      }
    }
  }
}

/// The text inside a message bubble: selectable, with clickable links, and sized to its content
/// up to `preferredMaxLayoutWidth`.
final class MessageTextView: NSTextView {
  var onLinkClicked: ((URL) -> Void)?

  var preferredMaxLayoutWidth: CGFloat = 0 {
    didSet {
      if preferredMaxLayoutWidth != oldValue { invalidateIntrinsicContentSize() }
    }
  }

  /// TextKit 1 stack, built by hand so sizing can use `NSLayoutManager.usedRect(for:)`.
  private let storage = NSTextStorage()

  init() {
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = false
    isVerticallyResizable = false
    isHorizontallyResizable = false
    font = .preferredFont(forTextStyle: .body)
    delegate = self
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(text: String, links: [MessageLink], textColor: NSColor, linkColor: NSColor) {
    let attributed = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: NSFont.preferredFont(forTextStyle: .body),
        .foregroundColor: textColor,
      ]
    )
    for link in links where NSMaxRange(link.range) <= attributed.length {
      attributed.addAttribute(.link, value: link.url, range: link.range)
    }
    linkTextAttributes = [
      .foregroundColor: linkColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    textStorage?.setAttributedString(attributed)
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: NSSize {
    guard let textContainer, let layoutManager else { return .zero }
    let maxWidth = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : 10_000
    textContainer.containerSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    return NSSize(width: ceil(used.width), height: ceil(used.height))
  }

  /// When not selectable (e.g. a failed message waiting to be retried), clicks fall through to the
  /// table row.
  override func hitTest(_ point: NSPoint) -> NSView? {
    isSelectable ? super.hitTest(point) : nil
  }
}

extension MessageTextView: NSTextViewDelegate {
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
    guard let url else { return false }
    onLinkClicked?(url)
    return true
  }
}
