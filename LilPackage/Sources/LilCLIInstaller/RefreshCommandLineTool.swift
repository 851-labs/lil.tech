#if os(macOS)
  public import SwiftUI

  extension View {
    /// Keeps an installed `lil` as new as the one the app bundles: once per launch, it replaces an
    /// older installed copy where this account can without a password (`~/.local/bin`, a
    /// `/usr/local/bin` the account owns), so a Sparkle update reaches `lil` too. Where only an
    /// administrator can, it offers to, once per version, rather than asking for a password
    /// nobody expected.
    ///
    /// For the app's main window: the offer is an alert on it.
    public func refreshesCommandLineTool() -> some View {
      modifier(RefreshCommandLineTool())
    }
  }

  /// Whether this launch has looked already: the main window can close and open again.
  @MainActor private var hasRefreshed = false

  private struct RefreshCommandLineTool: ViewModifier {
    @State private var offer: CommandLineToolInstaller.Outdated?
    /// The bundled version last offered, so an offer comes once per version.
    @AppStorage("lilCommandLineToolOfferedVersion") private var offeredVersion = 0

    func body(content: Content) -> some View {
      content
        .task {
          guard !hasRefreshed else { return }
          hasRefreshed = true
          guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else { return }
          let result = await CommandLineToolInstaller.refreshInstalled(bundled)
          guard
            let outdated = result.outdated.first,
            CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: offeredVersion)
          else { return }
          offeredVersion = outdated.bundledVersion
          offer = outdated
        }
        .alert(
          "Update the lil command line tool?",
          isPresented: Binding {
            offer != nil
          } set: {
            if !$0 { offer = nil }
          },
          presenting: offer
        ) { outdated in
          Button("Update") {
            guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else { return }
            Task { await install(bundled, into: outdated.directory) }
          }
          Button("Not Now", role: .cancel) {}
        } message: { outdated in
          Text(
            """
            The lil in \(outdated.directory.path) is version \(outdated.version), older than the \
            one \(appName) includes (version \(outdated.bundledVersion)). Updating it asks for an \
            administrator’s password.
            """
          )
        }
    }
  }
#endif
