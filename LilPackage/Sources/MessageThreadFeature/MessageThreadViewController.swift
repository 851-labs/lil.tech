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
  private var isGroup = false
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
    view = scrollView
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    dataSource = NSTableViewDiffableDataSource(tableView: tableView) {
      [unowned self] tableView, _, _, item in
      let cell =
        tableView.makeView(withIdentifier: MessageCellView.identifier, owner: nil)
        as? MessageCellView ?? MessageCellView()
      switch item {
      case .message(let id):
        if let message = messagesByID[id] {
          let sender = isGroup && !message.isFromMe ? message.senderAddress : nil
          cell.configure(with: message, senderName: sender.map { senderNames[$0] ?? $0 })
        }
      case .pending(let id):
        if let pending = pendingByID[id] {
          cell.configure(with: pending)
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

    observe { [weak self] in
      guard let self else { return }
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
    let items = messages.map { Item.message($0.id) } + pendingMessages.map { Item.pending($0.id) }
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
    messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    pendingByID = Dictionary(uniqueKeysWithValues: pendingMessages.map { ($0.id, $0) })

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
  }

  private var isScrolledToBottom: Bool {
    guard let documentView = scrollView.documentView else { return true }
    let visible = scrollView.contentView.bounds
    return visible.maxY >= documentView.bounds.height - 40
  }

  @objc private func boundsDidChange() {
    if scrollView.contentView.bounds.minY < 300 {
      store.send(.scrolledNearTop)
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
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")
  private let senderLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var senderHeightConstraint: NSLayoutConstraint!
  private var statusHeightConstraint: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier

    bodyLabel.isSelectable = true
    bodyLabel.font = .preferredFont(forTextStyle: .body)
    bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    for label in [senderLabel, statusLabel] {
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
    }

    for subview in [bubble, bodyLabel, senderLabel, statusLabel] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(senderLabel)
    addSubview(bubble)
    addSubview(statusLabel)
    bubble.addSubview(bodyLabel)

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

      bodyLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
      bodyLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
      bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
      bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: ThreadMessage, senderName: String?) {
    let body = message.body
    configure(
      text: body.isEmpty && message.hasAttachments ? "Attachment" : body,
      isFromMe: message.isFromMe,
      senderName: senderName,
      status: nil
    )
    bubble.alphaValue = 1
  }

  func configure(with pending: MessageThreadFeature.PendingMessage) {
    configure(
      text: pending.text,
      isFromMe: true,
      senderName: nil,
      status: pending.isFailed ? "Not Delivered · Click to Retry" : "Sending…"
    )
    bubble.alphaValue = pending.isFailed ? 1 : 0.6
    if pending.isFailed {
      bubble.layer?.backgroundColor = NSColor.systemRed.cgColor
      statusLabel.textColor = .systemRed
    }
  }

  private func configure(text: String, isFromMe: Bool, senderName: String?, status: String?) {
    bodyLabel.stringValue = text
    bodyLabel.textColor = isFromMe ? .white : .labelColor
    bubble.layer?.backgroundColor =
      isFromMe
      ? NSColor.controlAccentColor.cgColor
      : NSColor.unemphasizedSelectedContentBackgroundColor.cgColor

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

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
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
