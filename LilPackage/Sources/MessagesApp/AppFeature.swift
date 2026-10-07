public import ComposableArchitecture
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
    case conversationList(ConversationListFeature.Action)
    case fullDiskAccess(FullDiskAccessFeature.Action)
    case task
    case thread(MessageThreadFeature.Action)
  }

  @Dependency(\.chatDatabase) var chatDatabase

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
        return .none

      case .conversationList:
        let selection = state.conversationList.selection
        guard selection != state.thread?.chatID else { return .none }
        state.thread = selection.flatMap { id in
          state.conversationList.conversations.first { $0.id == id }
        }
        .map { conversation in
          MessageThreadFeature.State(
            chatID: conversation.id,
            title: conversation.title,
            isGroup: conversation.style == .group
          )
        }
        return .none

      case .fullDiskAccess(.delegate(.accessGranted)):
        state.hasFullDiskAccess = true
        state.fullDiskAccess = nil
        return .none

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
