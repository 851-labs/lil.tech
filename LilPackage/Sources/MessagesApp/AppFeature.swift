public import ComposableArchitecture
import ContactNames
public import ConversationListFeature
public import MessageThreadFeature
import MessagesDatabase
public import OnboardingFeature

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var conversationList = ConversationListFeature.State()
    public var fullDiskAccess: FullDiskAccessFeature.State?
    public var hasFullDiskAccess: Bool?
    public var thread: MessageThreadFeature.State?

    public init() {}
  }

  public enum Action {
    case accessChecked(isGranted: Bool)
    case contactsAccessResolved
    case conversationList(ConversationListFeature.Action)
    case fullDiskAccess(FullDiskAccessFeature.Action)
    case task
    case thread(MessageThreadFeature.Action)
  }

  @Dependency(\.chatDatabase) var chatDatabase
  @Dependency(\.contactNames) var contactNames

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.conversationList, action: \.conversationList) {
      ConversationListFeature()
    }
    Reduce { state, action in
      switch action {
      case .accessChecked(let isGranted):
        state.hasFullDiskAccess = isGranted
        state.fullDiskAccess = isGranted ? nil : FullDiskAccessFeature.State()
        return isGranted ? requestContactsAccess() : .none

      case .contactsAccessResolved:
        return .send(.conversationList(.contactsAccessChanged))

      case .conversationList:
        let contactNames = state.conversationList.contactNames
        let conversation = state.conversationList.selection.flatMap { id in
          state.conversationList.conversations.first { $0.id == id }
        }
        guard let conversation else {
          state.thread = nil
          return .none
        }
        let filter = state.conversationList.filter
        // A partly deleted chat is in both Messages and Recently Deleted, so the filter matters too.
        if state.thread?.chatID != conversation.id || state.thread?.filter != filter {
          state.thread = MessageThreadFeature.State(
            chatID: conversation.id,
            chatGUID: conversation.guid,
            title: conversation.title(contactNames: contactNames),
            isGroup: conversation.style == .group,
            senderNames: contactNames,
            filter: filter
          )
        } else {
          state.thread?.title = conversation.title(contactNames: contactNames)
          state.thread?.senderNames = contactNames
        }
        return .none

      case .fullDiskAccess(.delegate(.accessGranted)):
        state.hasFullDiskAccess = true
        state.fullDiskAccess = nil
        return requestContactsAccess()

      case .fullDiskAccess:
        return .none

      case .task:
        return .run { [chatDatabase] send in
          await send(.accessChecked(isGranted: (try? chatDatabase.reader()) != nil))
        }

      case .thread:
        return .none
      }
    }
    .ifLet(\.thread, action: \.thread) {
      MessageThreadFeature()
    }
    .ifLet(\.fullDiskAccess, action: \.fullDiskAccess) {
      FullDiskAccessFeature()
    }
  }
}

extension AppFeature {
  private func requestContactsAccess() -> Effect<Action> {
    .run { [contactNames] send in
      guard !contactNames.isAccessDetermined() else { return }
      _ = await contactNames.requestAccess()
      await send(.contactsAccessResolved)
    }
  }
}
