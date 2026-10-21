#if os(macOS)
  import AppKit
  public import SwiftUI

  /// Adds "Install Command Line Tool…" to the app menu, which installs the `lil` the app bundles
  /// (`Contents/MacOS/lil`).
  public struct InstallCommandLineToolCommands: Commands {
    public init() {}

    public var body: some Commands {
      CommandGroup(after: .appInfo) {
        Button("Install Command Line Tool…") {
          Task { await installCommandLineTool() }
        }
      }
    }
  }

  /// Asks where to install `lil`, installs it, and says how that went. Alerts rather than SwiftUI
  /// presentation: a menu command has no view to present from.
  @MainActor
  private func installCommandLineTool() async {
    let appName =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "the app"
    guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "lil") else {
      showAlert(
        "The command line tool is missing",
        "This copy of \(appName) doesn't include lil. Reinstall \(appName), then try again."
      )
      return
    }
    let shared = CommandLineToolInstaller.Destination.shared.directory.path
    let user = "~/.local/bin"
    let question = NSAlert()
    question.messageText = "Install the lil command line tool?"
    question.informativeText = """
      lil runs \(appName) from Terminal: try “lil help”. Install it in \(shared) for every \
      account on this Mac, which may ask for an administrator’s password, or in \(user) for \
      yours alone.
      """
    question.addButton(withTitle: "Install in \(shared)")
    question.addButton(withTitle: "Install in \(user)")
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

    do {
      switch try await CommandLineToolInstaller.install(bundled, into: destination.directory) {
      case .installed(let url, let replacedVersion):
        let replaced = replacedVersion.map { " It replaced an older lil (version \($0))." } ?? ""
        let path =
          destination == .user
          ? " If your shell can’t find it, add \(user) to your PATH." : ""
        showAlert("lil is installed", "lil is at \(url.path).\(replaced)\(path)")
      case .upToDate(let url, let version):
        showAlert(
          "lil is already installed",
          "The lil at \(url.path) (version \(version)) is this version or newer, so it was kept."
        )
      case .otherCommand(let url):
        showAlert(
          "Another lil is installed",
          """
          \(url.path) is another command named lil, so it was left alone. Remove it to install \
          this one.
          """
        )
      case .cancelled:
        break
      }
    } catch {
      showAlert("lil couldn’t be installed", error.localizedDescription)
    }
  }

  @MainActor
  private func showAlert(_ message: String, _ information: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = information
    alert.runModal()
  }
#endif
