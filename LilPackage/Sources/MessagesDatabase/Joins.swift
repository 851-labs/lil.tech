public import Foundation
public import SQLiteData

@Table("chat_handle_join")
public struct ChatHandleJoin: Sendable {
  @Column("chat_id")
  public var chatID: Chat.ID
  @Column("handle_id")
  public var handleID: Handle.ID

  public init(chatID: Chat.ID, handleID: Handle.ID) {
    self.chatID = chatID
    self.handleID = handleID
  }
}

@Table("chat_message_join")
public struct ChatMessageJoin: Sendable {
  @Column("chat_id")
  public var chatID: Chat.ID
  @Column("message_id")
  public var messageID: Message.ID
  @Column("message_date", as: Date.AppleTimestampRepresentation.self)
  public var messageDate: Date

  public init(chatID: Chat.ID, messageID: Message.ID, messageDate: Date) {
    self.chatID = chatID
    self.messageID = messageID
    self.messageDate = messageDate
  }
}
