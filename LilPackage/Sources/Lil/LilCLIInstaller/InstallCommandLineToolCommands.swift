#if os(macOS)
  import AppKit
  public import SwiftUI

  /// Adds "Install Command Line Tool…" to the app menu, which installs the `lil` the app bundles
  /// (`Contents/MacOS/lil`).
  public struct InstallCommandLineToolCommands: Commands {
    public init() {}

    public var body: some Commands {
      CommandGroup(after: .appInfo) {
        InstallCommandLineToolButton()
      }
    }
  }

  /// "Install Command Line Tool…": the menu item, and a settings pane's button where `lil` isn't
  /// installed yet.
  public struct InstallCommandLineToolButton: View {
    public init() {}

    public var body: some View {
      Button("Install Command Line Tool…") {
        Task { await installCommandLineTool() }
      }
    }
  }

  /// Whether an install is under way, so starting another meanwhile does nothing.
  @MainActor private var isInstalling = false

  /// Asks where to install `lil`, installs it, and says how that went. Alerts rather than SwiftUI
  /// presentation: a menu command has no view to present from.
  @MainActor
  private func installCommandLineTool() async {
    // Before asking where: an install already under way would ignore the answer.
    guard !isInstalling else { return }
    guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else {
      showAlert(
        "The command line tool is missing",
        "Reinstall \(appName), then try again."
      )
      return
    }
    // For all users is /usr/local/bin, for me only ~/.local/bin: the alert after says where it went.
    let question = NSAlert()
    question.messageText = "Install the lil command line tool?"
    question.informativeText = "Use \(appName) from Terminal."
    question.addButton(withTitle: "Install for All Users")
    question.addButton(withTitle: "Install for Me Only")
    question.addButton(withTitle: "Cancel")
    let destination: CommandLineToolInstaller.Destination
    switch question.runModal() {
    case .alertFirstButtonReturn:
      destination = .shared
    case .alertSecondButtonReturn:
      destination = .user
    default:
      return
    }

    await install(bundled, into: destination.directory)
  }

  /// Installs `bundled` into `directory`, and says how that went.
  @MainActor
  func install(_ bundled: URL, into directory: URL) async {
    guard !isInstalling else { return }
    isInstalling = true
    defer { isInstalling = false }
    do {
      switch try await CommandLineToolInstaller.install(bundled, into: directory) {
      case .installed(let url, _):
        let path =
          directory == CommandLineToolInstaller.Destination.user.directory
          ? " If your shell can’t find it, add ~/.local/bin to your PATH." : ""
        showAlert("lil is installed", "It’s at \(url.path). Try “lil help” in Terminal.\(path)")
      case .upToDate(let url, _):
        showAlert(
          "lil is already installed",
          "The lil at \(url.path) is up to date."
        )
      case .otherCommand(let url):
        showAlert(
          "Another lil is installed",
          "\(url.path) is a different command named lil. Remove it to install this one."
        )
      case .cancelled:
        break
      }
    } catch {
      showAlert("lil couldn’t be installed", error.localizedDescription)
    }
  }

  /// The app's name, as the menu bar shows it.
  @MainActor
  var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "the app"
  }

  @MainActor
  private func showAlert(_ message: String, _ information: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = information
    alert.runModal()
  }
#endif
