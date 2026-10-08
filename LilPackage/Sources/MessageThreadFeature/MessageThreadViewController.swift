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
  private var receiptMessageID: Message.ID?
  private var hasScrolledToBottomAfterLayout = false
  private var rowHeights: [Item: CGFloat] = [:]
  private var rowHeightsWidth: CGFloat = 0
  private lazy var sizingMessageCell = MessageCellView()
  private lazy var sizingSeparatorCell = SeparatorCellView()

  enum Item: Hashable {
    case message(Message.ID)
    case pending(UUID)
    case separator(Date)
  }

  /// The table's rows: messages, then pending messages, with a timestamp separator wherever
  /// Messages shows one.
  static func items(
    messages: [ThreadMessage],
    pendingMessages: [MessageThreadFeature.PendingMessage]
  ) -> [Item] {
    var items: [Item] = []
    var seenItems = Set<Item>()
    var previousDate: Date?
    func append(_ item: Item, at date: Date) {
      guard seenItems.insert(item).inserted else { return }
      if needsThreadSeparator(at: date, after: previousDate),
        seenItems.insert(.separator(date)).inserted
      {
        items.append(.separator(date))
      }
      items.append(item)
      previousDate = date
    }
    for message in messages {
      append(.message(message.id), at: message.date)
    }
    for pending in pendingMessages {
      append(.pending(pending.id), at: pending.sentAt)
    }
    return items
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
      if case .separator(let date) = item {
        let cell =
          tableView.makeView(withIdentifier: SeparatorCellView.identifier, owner: nil)
          as? SeparatorCellView ?? SeparatorCellView()
        cell.configure(with: ThreadTimestamp(date, now: Date()))
        return cell
      }
      let cell =
        tableView.makeView(withIdentifier: MessageCellView.identifier, owner: nil)
        as? MessageCellView ?? MessageCellView()
      cell.onLinkClicked = { [weak self] url in
        self?.store.send(.linkTapped(url))
      }
      configure(cell, for: item, rowWidth: tableView.bounds.width)
      return cell
    }
    tableView.delegate = self

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
      isTextChat = store.isTextChat
      apply(
        messages: store.messages,
        pendingMessages: store.pendingMessages,
        isGroup: store.isGroup,
        senderNames: store.senderNames,
        receiptMessageID: store.receiptMessageID
      )
    }
  }

  private func apply(
    messages: [ThreadMessage],
    pendingMessages: [MessageThreadFeature.PendingMessage],
    isGroup: Bool,
    senderNames: [String: String],
    receiptMessageID: Message.ID?
  ) {
    let items = Self.items(messages: messages, pendingMessages: pendingMessages)
    let previousItems = dataSource.snapshot().itemIdentifiers
    let wasAtBottom = isScrolledToBottom
    let distanceFromBottom =
      (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.origin.y
    let prependedEarlierMessages =
      previousItems.first.map { first in items.first != first } ?? false
      && previousItems.last == items.last

    let senderNamesChanged = senderNames != self.senderNames
    let previousReceiptMessageID = self.receiptMessageID
    self.isGroup = isGroup
    self.senderNames = senderNames
    self.receiptMessageID = receiptMessageID
    var changedItems = messages.compactMap { message -> Item? in
      guard let previous = messagesByID[message.id] else { return nil }
      let receiptChanged =
        previousReceiptMessageID != receiptMessageID
        && (message.id == previousReceiptMessageID || message.id == receiptMessageID)
      return senderNamesChanged || receiptChanged || previous != message
        ? .message(message.id) : nil
    }
    changedItems += pendingMessages.compactMap { pending -> Item? in
      guard let previous = pendingByID[pending.id], previous != pending else { return nil }
      return .pending(pending.id)
    }
    for case .message(let id) in changedItems {
      linksByID[id] = nil
    }
    for item in changedItems {
      rowHeights[item] = nil
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
    let changedRows = IndexSet(changedItems.compactMap { dataSource.row(forItemIdentifier: $0) })
    if !changedRows.isEmpty {
      tableView.noteHeightOfRows(withIndexesChanged: changedRows)
    }
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

  /// Messages applied before the table has a size can't be scrolled to; scroll to the latest once
  /// the first layout happens.
  override func viewDidLayout() {
    super.viewDidLayout()
    guard !hasScrolledToBottomAfterLayout, view.bounds.height > 0, tableView.numberOfRows > 0
    else { return }
    hasScrolledToBottomAfterLayout = true
    tableView.layoutSubtreeIfNeeded()
    tableView.scrollRowToVisible(tableView.numberOfRows - 1)
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

  private func configure(_ cell: MessageCellView, for item: Item, rowWidth: CGFloat) {
    let maxTextWidth = MessageCellView.maxTextWidth(forRowWidth: rowWidth)
    switch item {
    case .message(let id):
      if let message = messagesByID[id] {
        let sender = isGroup && !message.isFromMe ? message.senderAddress : nil
        cell.configure(
          with: message,
          links: links(for: message),
          senderName: sender.map { senderNames[$0] ?? formattedHandle($0) },
          status: MessageStatus.of(message, showsReceipt: id == receiptMessageID),
          maxTextWidth: maxTextWidth
        )
      }
    case .pending(let id):
      if let pending = pendingByID[id] {
        cell.configure(with: pending, isTextMessage: isTextChat, maxTextWidth: maxTextWidth)
      }
    case .separator:
      break
    }
  }

  /// Measures a row with an offscreen cell configured like the real one. Heights are explicit, not
  /// automatic, so the document height is exact before anything scrolls: automatic heights only
  /// measure visible rows and estimate the rest, which made scroll-to-bottom and the anchoring of
  /// prepended pages land in the wrong place.
  private func measureHeight(of item: Item, rowWidth: CGFloat) -> CGFloat {
    let cell: NSView
    if case .separator(let date) = item {
      sizingSeparatorCell.configure(with: ThreadTimestamp(date, now: Date()))
      cell = sizingSeparatorCell
    } else {
      configure(sizingMessageCell, for: item, rowWidth: rowWidth)
      cell = sizingMessageCell
    }
    let width = cell.widthAnchor.constraint(equalToConstant: rowWidth)
    width.isActive = true
    defer { width.isActive = false }
    cell.layoutSubtreeIfNeeded()
    return max(ceil(cell.fittingSize.height), 1)
  }

  /// The table row showing the message with `id`.
  func row(forMessage id: Message.ID) -> Int? {
    dataSource.row(forItemIdentifier: .message(id))
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
      rowHeights = [:]
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

extension MessageThreadViewController: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard let item = dataSource.itemIdentifier(forRow: row) else { return 1 }
    let width = tableView.bounds.width
    if width != rowHeightsWidth {
      rowHeights = [:]
      rowHeightsWidth = width
    }
    if let height = rowHeights[item] { return height }
    let height = measureHeight(of: item, rowWidth: width)
    rowHeights[item] = height
    return height
  }
}

/// A centered timestamp between messages, like "Today 12:06 PM".
final class SeparatorCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("SeparatorCellView")

  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with timestamp: ThreadTimestamp) {
    let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    let text = NSMutableAttributedString(
      string: timestamp.day,
      attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    text.append(
      NSAttributedString(
        string: timestamp.time,
        attributes: [
          .font: NSFont.systemFont(ofSize: size),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
      )
    )
    label.attributedStringValue = text
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
  private var statusLeadingConstraint: NSLayoutConstraint!
  private var statusTrailingConstraint: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier

    // Bubbles hug their text; the 70% width cap is only a maximum. Without high hugging the
    // bubble's width is ambiguous and Auto Layout stretches every bubble to the cap.
    bodyText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    bodyText.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    bodyText.setContentHuggingPriority(.defaultHigh, for: .vertical)

    for label in [senderLabel, statusLabel] {
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
    }
    statusLabel.maximumNumberOfLines = 2

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
    statusLeadingConstraint = statusLabel.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: 28)
    statusTrailingConstraint = statusLabel.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -28)

    NSLayoutConstraint.activate([
      senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),

      bubble.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

      statusLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
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

  /// The bubble's frame in the cell.
  var bubbleFrame: NSRect { bubble.frame }

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
    status: MessageStatus?,
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
      status: Self.statusText(isEdited: message.dateEdited != nil, status: status)
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
      status: NSAttributedString(
        string: pending.isFailed ? "Not Delivered · Click to Retry" : "Sending…",
        attributes: Self.statusAttributes(
          color: pending.isFailed ? .systemRed : .secondaryLabelColor)
      )
    )
    bubble.alphaValue = pending.isFailed ? 1 : 0.6
  }

  /// "Edited" under edited messages, then the delivery status, with failures in red.
  static func statusText(isEdited: Bool, status: MessageStatus?) -> NSAttributedString? {
    var lines: [NSAttributedString] = []
    if isEdited {
      lines.append(NSAttributedString(string: "Edited", attributes: statusAttributes()))
    }
    if let status {
      lines.append(
        NSAttributedString(
          string: status.text(now: Date()),
          attributes: statusAttributes(
            color: status == .notDelivered ? .systemRed : .secondaryLabelColor)
        )
      )
    }
    guard !lines.isEmpty else { return nil }
    let text = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
      if index > 0 { text.append(NSAttributedString(string: "\n", attributes: statusAttributes())) }
      text.append(line)
    }
    return text
  }

  private static func statusAttributes(
    color: NSColor = .secondaryLabelColor
  ) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.preferredFont(forTextStyle: .caption1), .foregroundColor: color]
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
    status: NSAttributedString?
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

    let alignedStatus = NSMutableAttributedString(attributedString: status ?? NSAttributedString())
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = isFromMe ? .right : .left
    alignedStatus.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: alignedStatus.length))
    statusLabel.attributedStringValue = alignedStatus
    statusHeightConstraint.isActive = status == nil

    leadingConstraint.isActive = !isFromMe
    trailingConstraint.isActive = isFromMe
    statusLeadingConstraint.isActive = !isFromMe
    statusTrailingConstraint.isActive = isFromMe
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
