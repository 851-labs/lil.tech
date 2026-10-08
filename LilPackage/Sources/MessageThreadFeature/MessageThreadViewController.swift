import AppKit
import ComposableArchitecture
import Foundation
import MessagesDatabase

/// The message list, an AppKit leaf view per `docs/DECISIONS.md`: it only reads the store with
/// `observe { }` and talks back with `store.send`.
final class MessageThreadViewController: NSViewController {
  private let store: StoreOf<MessageThreadFeature>
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private var dataSource: NSTableViewDiffableDataSource<Int, Item>!
  private var messagesByID: [Message.ID: ThreadMessage] = [:]
  private var pendingByID: [UUID: MessageThreadFeature.PendingMessage] = [:]
  private var linksByID: [Message.ID: [MessageLink]] = [:]
  private var lastTableWidth: CGFloat = 0
  private var isGroup = false
  private var isTextChat = false
  private var senderNames: [String: String] = [:]

  enum Item: Hashable {
    case message(Message.ID)
    case pending(UUID)
  }

  init(store: StoreOf<MessageThreadFeature>) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.usesAutomaticRowHeights = true
    tableView.selectionHighlightStyle = .none
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.target = self
    tableView.action = #selector(rowClicked)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true
    view = scrollView
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    dataSource = NSTableViewDiffableDataSource(tableView: tableView) {
      [unowned self] tableView, _, _, item in
      let cell =
        tableView.makeView(withIdentifier: MessageCellView.identifier, owner: nil)
        as? MessageCellView ?? MessageCellView()
      let maxTextWidth = MessageCellView.maxTextWidth(forRowWidth: tableView.bounds.width)
      cell.onLinkClicked = { [weak self] url in
        self?.store.send(.linkTapped(url))
      }
      switch item {
      case .message(let id):
        if let message = messagesByID[id] {
          let sender = isGroup && !message.isFromMe ? message.senderAddress : nil
          cell.configure(
            with: message,
            links: links(for: message),
            senderName: sender.map { senderNames[$0] ?? formattedHandle($0) },
            maxTextWidth: maxTextWidth
          )
        }
      case .pending(let id):
        if let pending = pendingByID[id] {
          cell.configure(with: pending, isTextMessage: isTextChat, maxTextWidth: maxTextWidth)
        }
      }
      return cell
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(boundsDidChange),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewFrameDidChange),
      name: NSView.frameDidChangeNotification,
      object: scrollView.contentView
    )

    observe { [weak self] in
      guard let self else { return }
      isTextChat = store.chatGUID.hasPrefix("SMS;") || store.chatGUID.hasPrefix("RCS;")
      apply(
        messages: store.messages,
        pendingMessages: store.pendingMessages,
        isGroup: store.isGroup,
        senderNames: store.senderNames
      )
    }
  }

  private func apply(
    messages: [ThreadMessage],
    pendingMessages: [MessageThreadFeature.PendingMessage],
    isGroup: Bool,
    senderNames: [String: String]
  ) {
    var seenItems = Set<Item>()
    let items = (messages.map { Item.message($0.id) } + pendingMessages.map { Item.pending($0.id) })
      .filter { seenItems.insert($0).inserted }
    let previousItems = dataSource.snapshot().itemIdentifiers
    let wasAtBottom = isScrolledToBottom
    let distanceFromBottom =
      (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.origin.y
    let prependedEarlierMessages =
      previousItems.first.map { first in items.first != first } ?? false
      && previousItems.last == items.last

    let senderNamesChanged = senderNames != self.senderNames
    self.isGroup = isGroup
    self.senderNames = senderNames
    var changedItems = messages.compactMap { message -> Item? in
      guard let previous = messagesByID[message.id] else { return nil }
      return senderNamesChanged || previous != message ? .message(message.id) : nil
    }
    changedItems += pendingMessages.compactMap { pending -> Item? in
      guard let previous = pendingByID[pending.id], previous != pending else { return nil }
      return .pending(pending.id)
    }
    for case .message(let id) in changedItems {
      linksByID[id] = nil
    }
    messagesByID = Dictionary(
      messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    pendingByID = Dictionary(
      pendingMessages.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )

    var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
    snapshot.appendSections([0])
    snapshot.appendItems(items)
    snapshot.reloadItems(changedItems)
    dataSource.apply(snapshot, animatingDifferences: false)
    tableView.layoutSubtreeIfNeeded()

    let appendedPendingMessage = pendingMessages.contains {
      !previousItems.contains(.pending($0.id))
    }
    if previousItems.isEmpty || appendedPendingMessage
      || (wasAtBottom && !prependedEarlierMessages)
    {
      tableView.scrollRowToVisible(items.count - 1)
    } else if prependedEarlierMessages, let documentView = scrollView.documentView {
      scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: documentView.bounds.height - distanceFromBottom)
      )
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    updateBubbleGradients()
  }

  private var isScrolledToBottom: Bool {
    guard let documentView = scrollView.documentView else { return true }
    let visible = scrollView.contentView.bounds
    return visible.maxY >= documentView.bounds.height - 40
  }

  @objc private func boundsDidChange() {
    updateBubbleGradients()
    if scrollView.contentView.bounds.minY < 300 {
      store.send(.scrolledNearTop)
    }
  }

  /// Data detection runs once per message; the result is cached until the message changes.
  private func links(for message: ThreadMessage) -> [MessageLink] {
    if let links = linksByID[message.id] { return links }
    let links = MessageLink.detect(in: message.body)
    linksByID[message.id] = links
    return links
  }

  @objc private func scrollViewFrameDidChange() {
    let width = tableView.bounds.width
    if width != lastTableWidth {
      lastTableWidth = width
      tableView.noteHeightOfRows(
        withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }
    updateBubbleGradients()
  }

  @objc private func updateBubbleGradients() {
    let clipView = scrollView.contentView
    let visibleRect = clipView.bounds
    tableView.enumerateAvailableRowViews { rowView, _ in
      (rowView.view(atColumn: 0) as? MessageCellView)?
        .updateViewportPosition(in: clipView, visibleRect: visibleRect)
    }
  }

  @objc private func rowClicked() {
    guard
      tableView.clickedRow >= 0,
      case .pending(let id) = dataSource.itemIdentifier(forRow: tableView.clickedRow),
      pendingByID[id]?.isFailed == true
    else { return }
    store.send(.failedMessageTapped(id))
  }
}

final class MessageCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("MessageCellView")

  private let bubble = BubbleView()
  private let bodyText = MessageTextView()
  private let senderLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var senderHeightConstraint: NSLayoutConstraint!
  private var statusHeightConstraint: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier

    bodyText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    for label in [senderLabel, statusLabel] {
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
    }

    for subview in [bubble, bodyText, senderLabel, statusLabel] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(senderLabel)
    addSubview(bubble)
    addSubview(statusLabel)
    bubble.addSubview(bodyText)

    leadingConstraint = bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
    trailingConstraint = bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
    senderHeightConstraint = senderLabel.heightAnchor.constraint(equalToConstant: 0)
    statusHeightConstraint = statusLabel.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),

      bubble.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

      statusLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
      statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
      statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

      bodyText.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
      bodyText.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
      bodyText.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
      bodyText.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var onLinkClicked: ((URL) -> Void)? {
    get { bodyText.onLinkClicked }
    set { bodyText.onLinkClicked = newValue }
  }

  /// The widest the message text may get: bubbles are at most 70% of the row, minus padding.
  static func maxTextWidth(forRowWidth width: CGFloat) -> CGFloat {
    max(floor(width * 0.7) - 24, 0)
  }

  override func layout() {
    if bounds.width > 0 {
      bodyText.preferredMaxLayoutWidth = Self.maxTextWidth(forRowWidth: bounds.width)
    }
    super.layout()
  }

  func configure(
    with message: ThreadMessage,
    links: [MessageLink],
    senderName: String?,
    maxTextWidth: CGFloat
  ) {
    let body = message.body
    bodyText.preferredMaxLayoutWidth = maxTextWidth
    bodyText.isSelectable = true
    configure(
      text: body.isEmpty && message.hasAttachments ? "Attachment" : body,
      links: links,
      style: message.isFromMe ? (message.isTextMessage ? .textMessage : .iMessage) : .received,
      senderName: senderName,
      status: nil
    )
    bubble.alphaValue = 1
  }

  func configure(
    with pending: MessageThreadFeature.PendingMessage,
    isTextMessage: Bool,
    maxTextWidth: CGFloat
  ) {
    bodyText.preferredMaxLayoutWidth = maxTextWidth
    bodyText.isSelectable = !pending.isFailed
    configure(
      text: pending.text,
      links: [],
      style: pending.isFailed ? .failed : (isTextMessage ? .textMessage : .iMessage),
      senderName: nil,
      status: pending.isFailed ? "Not Delivered · Click to Retry" : "Sending…"
    )
    bubble.alphaValue = pending.isFailed ? 1 : 0.6
    if pending.isFailed {
      statusLabel.textColor = .systemRed
    }
  }

  /// Updates the iMessage gradient for the bubble's position within `visibleRect`, in the
  /// coordinates of `container`.
  func updateViewportPosition(in container: NSView, visibleRect: NSRect) {
    guard bubble.style == .iMessage, visibleRect.height > 0 else { return }
    let frame = bubble.convert(bubble.bounds, to: container)
    bubble.viewportFraction = (frame.midY - visibleRect.minY) / visibleRect.height
  }

  private func configure(
    text: String,
    links: [MessageLink],
    style: BubbleView.Style,
    senderName: String?,
    status: String?
  ) {
    let isFromMe = style != .received
    bodyText.configure(
      text: text,
      links: links,
      textColor: isFromMe ? .white : .labelColor,
      linkColor: isFromMe ? .white : .linkColor
    )
    bubble.style = style

    senderLabel.stringValue = senderName ?? ""
    senderHeightConstraint.isActive = senderName == nil

    statusLabel.stringValue = status ?? ""
    statusLabel.textColor = .secondaryLabelColor
    statusHeightConstraint.isActive = status == nil

    leadingConstraint.isActive = !isFromMe
    trailingConstraint.isActive = isFromMe
  }
}

/// A message bubble background whose corners stay clean at any height.
///
/// Bubbles use a 16pt continuous corner, but a single line of text is shorter than 32pt. A radius
/// larger than half the height makes the continuous curve overshoot, so short bubbles become
/// circular-cornered capsules instead.
final class BubbleView: NSView {
  nonisolated static let maximumCornerRadius: CGFloat = 16

  enum Style: Equatable {
    case failed
    case iMessage
    case received
    case textMessage
  }

  var style = Style.received {
    didSet { needsDisplay = true }
  }

  /// Where the bubble sits in the visible thread, from 0 (top) to 1 (bottom). Only affects iMessage
  /// bubbles, whose blue is a gradient across the viewport.
  var viewportFraction: CGFloat = 1 {
    didSet {
      if style == .iMessage, viewportFraction != oldValue { needsDisplay = true }
    }
  }

  override var wantsUpdateLayer: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  override func updateLayer() {
    let color: NSColor =
      switch style {
      case .failed: BubbleColors.failed
      case .iMessage: BubbleColors.iMessage(atFraction: viewportFraction)
      case .received: BubbleColors.received
      case .textMessage: BubbleColors.textMessage
      }
    layer?.backgroundColor = color.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    let corner = Self.corner(forHeight: bounds.height)
    layer?.cornerRadius = corner.radius
    layer?.cornerCurve = corner.curve
  }

  nonisolated static func corner(forHeight height: CGFloat) -> (
    radius: CGFloat, curve: CALayerCornerCurve
  ) {
    let halfHeight = height / 2
    return halfHeight > maximumCornerRadius
      ? (maximumCornerRadius, .continuous)
      : (halfHeight, .circular)
  }
}
