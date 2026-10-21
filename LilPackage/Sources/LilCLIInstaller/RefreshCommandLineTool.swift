#if os(macOS)
  public import SwiftUI

  /// Keeps an installed `lil` as new as the one the app bundles. When the app opens, which it does
  /// after every Sparkle update, it replaces an older installed copy where this account can without
  /// a password (`~/.local/bin`, a `/usr/local/bin` the account owns). Where only an administrator
  /// can, the main window offers to (`refreshesCommandLineTool()`), once per version, rather than
  /// asking for a password nobody expected.
  public enum CommandLineToolRefresh {
    /// This launch's refresh, started once.
    @MainActor private static var task: Task<CommandLineToolInstaller.RefreshResult, Never>?

    /// Starts the refresh, unless it's started already. For the app's `init`, so it runs whether
    /// or not a window opens.
    @MainActor
    @discardableResult
    public static func start() -> Task<CommandLineToolInstaller.RefreshResult, Never> {
      if let task { return task }
      let task = Task {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else {
          return CommandLineToolInstaller.RefreshResult()
        }
        return await CommandLineToolInstaller.refreshInstalled(bundled)
      }
      self.task = task
      return task
    }
  }

  extension View {
    /// Offers to update an installed `lil` that only an administrator can replace, once the
    /// launch's `CommandLineToolRefresh` finds one: an alert on this view, for the app's main
    /// window.
    public func refreshesCommandLineTool() -> some View {
      modifier(RefreshCommandLineTool())
    }
  }

  /// Whether this launch has offered already: the main window can close and open again.
  @MainActor private var hasOffered = false

  private struct RefreshCommandLineTool: ViewModifier {
    @State private var offer: [CommandLineToolInstaller.Outdated] = []
    /// The bundled version last offered, so an offer comes once per version.
    @AppStorage("lilCommandLineToolOfferedVersion") private var offeredVersion = 0

    func body(content: Content) -> some View {
      content
        .task {
          guard !hasOffered else { return }
          let outdated = await CommandLineToolRefresh.start().value.outdated
          // The window closed meanwhile: offer when it opens again.
          guard !Task.isCancelled, !hasOffered else { return }
          hasOffered = true
          guard
            let bundledVersion = outdated.map(\.bundledVersion).max(),
            CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: offeredVersion)
          else { return }
          offeredVersion = bundledVersion
          offer = outdated
        }
        .alert(
          "Update the lil command line tool?",
          isPresented: Binding {
            !offer.isEmpty
          } set: {
            if !$0 { offer = [] }
          },
          presenting: offer
        ) { outdated in
          Button("Update") {
            guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else { return }
            Task {
              for each in outdated {
                await install(bundled, into: each.directory)
              }
            }
          }
          Button("Not Now", role: .cancel) {}
        } message: { outdated in
          Text(message(outdated))
        }
    }

    private func message(_ outdated: [CommandLineToolInstaller.Outdated]) -> String {
      let bundledVersion = outdated.map(\.bundledVersion).max() ?? 0
      let installed = outdated.map { "\($0.directory.path) (version \($0.version))" }
        .formatted(.list(type: .and))
      let (lil, isOlder) =
        outdated.count == 1 ? ("The lil", "is older") : ("The lil commands", "are older")
      return """
        \(lil) in \(installed) \(isOlder) than the one \(appName) includes (version \
        \(bundledVersion)). Updating asks for an administrator’s password.
        """
    }
  }
#endif
