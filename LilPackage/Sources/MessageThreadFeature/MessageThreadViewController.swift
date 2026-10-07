import AppKit
import ComposableArchitecture
import MessagesDatabase

/// The message list, an AppKit leaf view per `docs/DECISIONS.md`: it only reads the store with
/// `observe { }` and talks back with `store.send`.
final class MessageThreadViewController: NSViewController {
  private let store: StoreOf<MessageThreadFeature>
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private var dataSource: NSTableViewDiffableDataSource<Int, Message.ID>!
  private var messagesByID: [Message.ID: ThreadMessage] = [:]
  private var isGroup = false
  private var senderNames: [String: String] = [:]

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

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.contentView.postsBoundsChangedNotifications = true
    view = scrollView
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    dataSource = NSTableViewDiffableDataSource(tableView: tableView) {
      [unowned self] tableView, _, _, id in
      let cell =
        tableView.makeView(withIdentifier: MessageCellView.identifier, owner: nil)
        as? MessageCellView ?? MessageCellView()
      if let message = messagesByID[id] {
        let sender = isGroup && !message.isFromMe ? message.senderAddress : nil
        cell.configure(with: message, senderName: sender.map { senderNames[$0] ?? $0 })
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
      apply(messages: store.messages, isGroup: store.isGroup, senderNames: store.senderNames)
    }
  }

  private func apply(messages: [ThreadMessage], isGroup: Bool, senderNames: [String: String]) {
    let previousIDs = dataSource.snapshot().itemIdentifiers
    let wasAtBottom = isScrolledToBottom
    let distanceFromBottom =
      (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.origin.y
    let prependedEarlierMessages =
      previousIDs.first.map { first in messages.first?.id != first } ?? false
      && previousIDs.last == messages.last?.id

    let senderNamesChanged = senderNames != self.senderNames
    self.isGroup = isGroup
    self.senderNames = senderNames
    let changedIDs = messages.compactMap { message in
      if senderNamesChanged, messagesByID[message.id] != nil {
        return message.id
      }
      return messagesByID[message.id].map { $0 != message ? message.id : nil } ?? nil
    }
    messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

    var snapshot = NSDiffableDataSourceSnapshot<Int, Message.ID>()
    snapshot.appendSections([0])
    snapshot.appendItems(messages.map(\.id))
    snapshot.reloadItems(changedIDs)
    dataSource.apply(snapshot, animatingDifferences: false)
    tableView.layoutSubtreeIfNeeded()

    if previousIDs.isEmpty || (wasAtBottom && !prependedEarlierMessages) {
      tableView.scrollRowToVisible(messages.count - 1)
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
}

final class MessageCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("MessageCellView")

  private let bubble = NSView()
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")
  private let senderLabel = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var senderHeightConstraint: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier

    bubble.wantsLayer = true
    bubble.layer?.cornerRadius = 16
    bubble.layer?.cornerCurve = .continuous

    bodyLabel.isSelectable = true
    bodyLabel.font = .preferredFont(forTextStyle: .body)
    bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    senderLabel.font = .preferredFont(forTextStyle: .caption1)
    senderLabel.textColor = .secondaryLabelColor
    senderLabel.lineBreakMode = .byTruncatingTail

    for subview in [bubble, bodyLabel, senderLabel] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(senderLabel)
    addSubview(bubble)
    bubble.addSubview(bodyLabel)

    leadingConstraint = bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
    trailingConstraint = bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
    senderHeightConstraint = senderLabel.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),

      bubble.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
      bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
      bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

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
    bodyLabel.stringValue = body.isEmpty && message.hasAttachments ? "Attachment" : body
    bodyLabel.textColor = message.isFromMe ? .white : .labelColor
    bubble.layer?.backgroundColor =
      message.isFromMe
      ? NSColor.controlAccentColor.cgColor
      : NSColor.unemphasizedSelectedContentBackgroundColor.cgColor

    senderLabel.stringValue = senderName ?? ""
    senderHeightConstraint.isActive = senderName == nil

    leadingConstraint.isActive = !message.isFromMe
    trailingConstraint.isActive = message.isFromMe
  }
}
