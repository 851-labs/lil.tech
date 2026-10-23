public import ComposableArchitecture
import LilAuth
import LilUI
public import SwiftUI

/// The app's Settings window (⌘, or lil health › Settings…), a tab per pane: the
/// account's (851-2717) and command-line and agent access (851-2840). It reads the app's store,
/// so it works whether or not the main window is open, and an export keeps going when it closes.
///
/// The window resizes (851-2992): each pane fills it, down to the same minimum, so switching tabs
/// never changes its size, and it opens at the size it last had (`ResizableWindow`).
public struct SettingsView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  /// Every pane's smallest size, and the window's when it first opens (the scene's
  /// `defaultSize`): the size it had before it resized. One for both panes, since a pane needing
  /// more room than the window has would grow it when its tab is chosen. Nonisolated for snapshot
  /// catalogs.
  public nonisolated static let minWidth: CGFloat = 480
  public nonisolated static let minHeight: CGFloat = 380

  public var body: some View {
    TabView {
      AccountSettingsView(store: store)
        .settingsPaneFrame()
        .tabItem { Label("Account", systemImage: "person.crop.circle") }
      AgentAccessSettingsView(store: store)
        .settingsPaneFrame()
        .tabItem { Label("Agents", systemImage: "terminal") }
    }
    .background(ResizableWindow())
  }
}

extension View {
  /// A pane's frame: at least the window's minimum, and filling whatever room the window has
  /// beyond it. On each pane rather than the `TabView`, since the window takes its size limits
  /// from the selected tab's content. No ideal size, so a pane's ideal is its content's, which the
  /// snapshot catalog grows to: the window opens at the scene's `defaultSize`.
  func settingsPaneFrame() -> some View {
    frame(
      minWidth: SettingsView.minWidth, maxWidth: .infinity,
      minHeight: SettingsView.minHeight, maxHeight: .infinity)
  }
}

/// Makes the window it's in resizable, and remembers its size between launches.
///
/// SwiftUI doesn't make the `Settings` scene's window resizable, whatever its content's frame or
/// `windowResizability` say (macOS 27), and takes `.resizable` out of its style mask again whenever
/// its content's size limits change, so this puts it back whenever the style mask changes. The
/// window keeps to the size limits SwiftUI sets from the selected pane's frame.
///
/// SwiftUI's own frame autosave restores where the window was, but not its size: it restores it
/// before the window is resizable, and AppKit only restores a resizable window's size. So this
/// keeps the size in the app's settings (`defaultAppStorage`, the server's suite in a dev build),
/// and sets it as the window opens, keeping its top left where SwiftUI put it.
private struct ResizableWindow: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { WindowView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class WindowView: NSView {
    /// The window's frame size, as `NSStringFromSize` makes it, e.g. `{760, 600}`.
    static let sizeKey = "settingsWindowSize"

    @Dependency(\.defaultAppStorage) private var defaults
    private var styleMaskObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      styleMaskObservation = nil
      guard let window else { return }
      makeWindowResizable()
      // The green button zooms it rather than taking it full screen, as a settings window should.
      window.collectionBehavior.insert(.fullScreenNone)
      // Only as it opens, not if SwiftUI hosts this view again while it's on screen.
      if !window.isVisible {
        restoreSize(of: window)
      }
      styleMaskObservation = window.observe(\.styleMask) { [weak self] _, _ in
        // KVO's handler is nonisolated; SwiftUI changes the style mask on the main thread.
        Task { @MainActor in self?.makeWindowResizable() }
      }
    }

    /// The view fills the window, so it resizes with it: the window's size is saved from here,
    /// once the window is on screen, rather than the sizes SwiftUI gives it as it opens.
    override func setFrameSize(_ newSize: NSSize) {
      let oldSize = frame.size
      super.setFrameSize(newSize)
      guard newSize != oldSize, let window, window.isVisible else { return }
      defaults.set(NSStringFromSize(window.frame.size), forKey: Self.sizeKey)
    }

    private func makeWindowResizable() {
      // Only when it isn't: setting the style mask notifies the observation again.
      guard let window, !window.styleMask.contains(.resizable) else { return }
      window.styleMask.insert(.resizable)
    }

    private func restoreSize(of window: NSWindow) {
      guard let saved = defaults.string(forKey: Self.sizeKey) else { return }
      let size = NSSizeFromString(saved)
      guard size.width > 0, size.height > 0 else { return }
      // Its top left stays where SwiftUI put it.
      var frame = window.frame
      frame.origin.y += frame.height - size.height
      frame.size = size
      window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: false)
    }
  }
}

/// The account's pane: its sign-in methods and exporting its data, or, signed out, how to get
/// them.
struct AccountSettingsView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    Group {
      switch store.isSignedIn {
      case nil:
        // The stored session isn't checked yet: its space, under the spinner `delayedProgress`
        // shows (851-3086).
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case false:
        ContentUnavailableView {
          Label("Not Signed In", systemImage: "person.crop.circle")
        } description: {
          Text("Sign in to lil health to see how you sign in and to export your data.")
        }
      case true:
        let account = store.scope(\.account, action: \.account)
        Form {
          SignInMethodsSection(store: account.scope(\.signInMethods, action: \.signInMethods))
          DataExportSection(store: account.scope(\.dataExport, action: \.dataExport))
        }
        .formStyle(.grouped)
      }
    }
    .delayedProgress(isLoading: store.isSignedIn == nil)
    .onAppear { store.send(.account(.appeared)) }
  }
}

/// Exporting the account's data: a button, then how the export is going.
struct DataExportSection: View {
  let store: StoreOf<DataExportFeature>

  var body: some View {
    Section {
      switch store.status {
      case .idle, .failed:
        Button("Export Data…") { store.send(.exportButtonTapped) }
      case .preparing:
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Preparing your export…")
          Spacer()
          Button("Cancel") { store.send(.cancelButtonTapped) }
        }
      case .downloading(let share):
        HStack {
          ProgressView(value: share) {
            Text("Downloading…")
          } currentValueLabel: {
            Text(share.formatted(.percent.precision(.fractionLength(0))))
          }
          Button("Cancel") { store.send(.cancelButtonTapped) }
        }
      case .saving:
        Text("Choose where to save your export.")
          .foregroundStyle(.secondary)
      case .saved(let url):
        HStack {
          Label {
            Text(url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          } icon: {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
          Spacer()
          Button("Show in Finder") { store.send(.showInFinderButtonTapped) }
        }
      }
    } header: {
      Text("Your Data")
    } footer: {
      if case .failed(let message) = store.status {
        Text(message)
          .foregroundStyle(.red)
      } else {
        Text(
          "A copy of everything in your account, as an archive: your account details, synced Health records and attachments. One export a day."
        )
      }
    }
  }
}
