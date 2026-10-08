public import ComposableArchitecture
public import Foundation
import MessageSending
public import MessagesDatabase
import SQLiteData
public import Tagged

@Reducer
public struct MessageThreadFeature {
  public static let pageSize = 100

  @ObservableState
  public struct State: Equatable, Identifiable {
    public let chatGUID: String
    public let chatID: Chat.ID
    public var draft: String
    public var hasEarlierMessages: Bool
    public var isGroup: Bool
    public var isLoadingEarlier: Bool
    public var loadFailed: Bool
    public var messages: [ThreadMessage]
    public var pendingMessages: [PendingMessage]
    public var senderNames: [String: String]
    public var title: String

    public var id: Chat.ID { chatID }

    public init(
      chatID: Chat.ID,
      chatGUID: String,
      title: String,
      isGroup: Bool,
      messages: [ThreadMessage] = [],
      senderNames: [String: String] = [:],
      draft: String = "",
      pendingMessages: [PendingMessage] = [],
      hasEarlierMessages: Bool = true,
      isLoadingEarlier: Bool = false,
      loadFailed: Bool = false
    ) {
      self.chatGUID = chatGUID
      self.chatID = chatID
      self.draft = draft
      self.hasEarlierMessages = hasEarlierMessages
      self.isGroup = isGroup
      self.isLoadingEarlier = isLoadingEarlier
      self.loadFailed = loadFailed
      self.messages = messages
      self.pendingMessages = pendingMessages
      self.senderNames = senderNames
      self.title = title
    }
  }

  /// A message sent from lil messages that hasn't shown up in `chat.db` yet.
  public struct PendingMessage: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var sentAt: Date
    public var isFailed: Bool

    public init(id: UUID, text: String, sentAt: Date, isFailed: Bool = false) {
      self.id = id
      self.text = text
      self.sentAt = sentAt
      self.isFailed = isFailed
    }
  }

  public enum Action {
    case draftChanged(String)
    case earlierMessagesLoaded(Result<[ThreadMessage], any Error>)
    case failedMessageTapped(UUID)
    case latestMessagesLoaded(Result<[ThreadMessage], any Error>)
    case linkTapped(URL)
    case returnKeyPressed
    case scrolledNearTop
    case sendResponse(id: UUID, Result<Void, any Error>)
    case task
  }

  @Dependency(\.chatDatabase) var chatDatabase
  @Dependency(\.chatDatabaseChanges) var chatDatabaseChanges
  @Dependency(\.date.now) var now
  @Dependency(\.messageSender) var messageSender
  @Dependency(\.openURL) var openURL
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .draftChanged(let draft):
        state.draft = draft
        return .none

      case .earlierMessagesLoaded(.success(let earlier)):
        state.isLoadingEarlier = false
        state.hasEarlierMessages = earlier.count == Self.pageSize
        let existingIDs = Set(state.messages.map(\.id))
        state.messages.insert(contentsOf: earlier.filter { !existingIDs.contains($0.id) }, at: 0)
        return .none

      case .earlierMessagesLoaded(.failure):
        state.isLoadingEarlier = false
        return .none

      case .failedMessageTapped(let id):
        guard let index = state.pendingMessages.firstIndex(where: { $0.id == id && $0.isFailed })
        else { return .none }
        state.pendingMessages[index].isFailed = false
        state.pendingMessages[index].sentAt = now
        return send(state.pendingMessages[index], to: state.chatGUID)

      case .latestMessagesLoaded(.success(let latest)):
        state.loadFailed = false
        if state.messages.isEmpty {
          state.hasEarlierMessages = latest.count == Self.pageSize
        }
        let latestIDs = Set(latest.map(\.id))
        let oldestLatest = latest.first?.cursor
        state.messages.removeAll { message in
          latestIDs.contains(message.id)
            || oldestLatest.map { !message.cursor.isBefore($0) } ?? false
        }
        state.messages.append(contentsOf: latest)
        state.pendingMessages.removeAll { pending in
          !pending.isFailed && latest.contains { pending.isConfirmed(by: $0) }
        }
        return .none

      case .latestMessagesLoaded(.failure):
        state.loadFailed = true
        return .none

      case .linkTapped(let url):
        return .run { [openURL] _ in
          await openURL(url)
        }

      case .returnKeyPressed:
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        let pending = PendingMessage(id: uuid(), text: text, sentAt: now)
        state.draft = ""
        state.pendingMessages.append(pending)
        return send(pending, to: state.chatGUID)

      case .scrolledNearTop:
        guard
          state.hasEarlierMessages,
          !state.isLoadingEarlier,
          let oldest = state.messages.first?.cursor
        else { return .none }
        state.isLoadingEarlier = true
        let request = MessageThreadRequest(
          chatID: state.chatID, before: oldest, limit: Self.pageSize)
        return .run { [chatDatabase] send in
          await send(.earlierMessagesLoaded(await fetch(request, from: chatDatabase)))
        }

      case .sendResponse(_, .success):
        return .none

      case .sendResponse(let id, .failure):
        guard let index = state.pendingMessages.firstIndex(where: { $0.id == id })
        else { return .none }
        state.pendingMessages[index].isFailed = true
        return .none

      case .task:
        let request = MessageThreadRequest(chatID: state.chatID, limit: Self.pageSize)
        return .run { [chatDatabase, chatDatabaseChanges] send in
          let changes = chatDatabaseChanges.stream()
          await send(.latestMessagesLoaded(await fetch(request, from: chatDatabase)))
          for await _ in changes {
            await send(.latestMessagesLoaded(await fetch(request, from: chatDatabase)))
          }
        }
      }
    }
  }

  private func send(_ pending: PendingMessage, to chatGUID: String) -> Effect<Action> {
    .run { [messageSender] send in
      await send(
        .sendResponse(
          id: pending.id,
          Result { try await messageSender.send(pending.text, chatGUID) }
        )
      )
    }
  }
}

extension MessageThreadFeature.PendingMessage {
  /// Whether `message` is this pending message, now written to `chat.db` by Messages.
  ///
  /// Messages doesn't report the ID of a message sent through AppleScript, so a pending message
  /// is matched to an outgoing message with the same text sent around the same time.
  func isConfirmed(by message: ThreadMessage) -> Bool {
    message.isFromMe
      && message.body == text
      && message.date >= sentAt.addingTimeInterval(-10)
  }
}

private func fetch(
  _ request: MessageThreadRequest,
  from chatDatabase: ChatDatabase
) async -> Result<[ThreadMessage], any Error> {
  await Result {
    try await chatDatabase.reader().read { db in
      try request.fetch(db)
    }
  }
}

extension MessageThreadRequest.Cursor {
  func isBefore(_ other: Self) -> Bool {
    (date, id.rawValue) < (other.date, other.id.rawValue)
  }
}
