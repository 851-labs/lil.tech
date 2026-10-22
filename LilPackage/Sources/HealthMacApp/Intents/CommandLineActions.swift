import Foundation
import HealthAgentAccess

// The command line's requests (851-2895), in the app's terms: `AppFeature` claims them from
// `AgentAccess.sqlite` and performs them through `HealthAppActions`, as the intents' are.

extension HealthAppAction {
  /// What the command line asked for. Fails for a page this version doesn't have.
  init(_ action: AgentAction) throws {
    switch action {
    case .open(let id):
      guard let page = HealthPage(id: id) else { throw AgentActionFailure.unknownPage(id) }
      self = .open(page)
    case .sync:
      self = .sync
    case .export(let folder):
      // A relative path would be the app's, not the command's: the command sends absolute ones.
      guard folder.hasPrefix("/") else {
        throw AgentActionFailure(reason: .failed, message: "There's no folder at \(folder).")
      }
      self = .export(to: URL(filePath: folder, directoryHint: .isDirectory))
    }
  }
}

extension AgentActionResult {
  init(_ result: HealthAppActionResult) {
    switch result {
    case .done: self = .done
    case .synced(let date): self = .synced(at: date)
    case .stillSyncing: self = .stillSyncing
    case .exported(let url): self = .exported(path: url.path(percentEncoded: false))
    }
  }
}

extension AgentActionFailure {
  /// Why an action failed, with the message the intents show.
  init(_ error: any Error) {
    switch error {
    case HealthAppActionError.signedOut: self = .signedOut
    case let error as AgentActionFailure: self = error
    default: self.init(reason: .failed, message: error.localizedDescription)
    }
  }

  /// A page ID this version of the app doesn't have.
  static func unknownPage(_ id: String) -> Self {
    Self(reason: .failed, message: "lil health has no page \(id).")
  }
}
