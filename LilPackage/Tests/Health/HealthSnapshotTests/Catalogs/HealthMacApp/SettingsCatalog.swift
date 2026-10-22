#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import HealthAgentAccess
  import HealthDatabase
  @testable import HealthMacApp
  import LilAuth
  import SwiftUI
  import Testing

  // The Settings window's panes, at its smallest size unless a state says otherwise: Account
  // (`AccountSettingsView`) and Agents (`AgentAccessSettingsView`), each signed in, signed out and
  // checking the session; then how to connect a local agent (`AgentSetupSection`) and the remote
  // agents (`ConnectedAgentsSections`) on their own, and the Agents pane's two logs, each a sheet
  // over the window (851-3082), at the size it opens at. The window resizes (851-2992), so each
  // pane has a state in a large window too, where its rows widen. The window shows its tabs in the
  // toolbar, which these don't. Synthetic data only: made-up sign-in methods, queries, agents and
  // reads.
  //
  // `EmptyReducer`s, so the panes' tasks don't replace the states shown. Switches that are on
  // draw gray: their tint is Liquid Glass, which doesn't render offscreen (851-2957). The panes
  // grow to their content, where the window (at least 480 by 380 pt) scrolls them, and Account
  // and Agents have the window's pane frame (`settingsPaneFrame()`), so signed out is centered as
  // the window shows it. The MCP server URL is staging's, whatever `LIL_API_URL` says
  // (`fixAPIEnvironment()`).

  extension MacSnapshotTests {
    @Test(arguments: settingsCatalog.selectedStates)
    func settings(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let settingsCatalog = StateCatalog(
    "Settings", width: SettingsView.minWidth, minHeight: SettingsView.minHeight,
    states: [
      // Account.
      CatalogState("Account") { account() },
      CatalogState("Loading sign-in methods") { account(methods: .loading) },
      CatalogState("Sign-in methods failed") {
        account(methods: .failed(SignInMethodError.unavailable.message))
      },
      CatalogState("Preparing an export") { account(export: .preparing) },
      CatalogState("Downloading an export") { account(export: .downloading(0.42)) },
      CatalogState("Saving an export") { account(export: .saving) },
      CatalogState("Export saved") {
        account(export: .saved(URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")))
      },
      CatalogState("Export failed") {
        account(export: .failed(DataExportError.unavailable.message))
      },
      CatalogState("Signed out") { account(isSignedIn: false) },
      CatalogState("Checking the session") { account(isSignedIn: nil) },
      CatalogState("Account: large window", width: largeWidth, minHeight: largeHeight) {
        account(export: .saved(URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")))
      },
      CatalogState("Signed out: large window", width: largeWidth, minHeight: largeHeight) {
        account(isSignedIn: false)
      },

      // Agents (851-2840), with what intents may do (851-2892). "Agents: on, with a log" was
      // `MacSnapshotTests.agentsPane` (851-2931), which kept to the window's height. The preview
      // "Agents: revoke an agent on all lil apps" isn't one: its alert is a sheet, a window of its
      // own that the image doesn't show, and the window's dimmed buttons draw differently on
      // macOS 27.0 and 27.0.1. Without the alert, it showed nothing that "Agents: on, with a log"
      // and "Remote agents" don't. `ConnectedAgentsFeatureTests` checks the alert's text.
      CatalogState("Agents: on, with a log") { agents() },
      CatalogState("Agents: on, empty log") { agents(entries: []) },
      CatalogState("Agents: off, with a log") { agents(isEnabled: false) },
      // How to connect an agent, before `lil` is installed (851-2865).
      CatalogState("Agents: without lil") { agents(entries: [], commandLineTool: nil) },
      CatalogState("Agents: off") { agents(isEnabled: false, entries: []) },
      CatalogState("Agents: loading") { agents(isEnabled: false, entries: [], isLoading: true) },
      CatalogState("Agents: failed") {
        agents(
          isEnabled: false, entries: [],
          failure: "lil health couldn't read or save this setting: The disk is full.")
      },
      CatalogState("Agents: log unreadable") {
        agents(
          entries: [],
          logFailure: "lil health couldn't read the access log: The database file is locked.")
      },
      CatalogState("Agents: signed out") { agents(isSignedIn: false) },
      // The long command lines on one line, and the access log's commands in full.
      CatalogState("Agents: large window", width: largeWidth, minHeight: largeHeight) {
        agents()
      },

      // How to connect a local agent (851-2865), on its own, tall enough to see it all:
      // `lil mcp` first, then `lil health mcp` for lil health only (851-2898).
      CatalogState("Connect an agent", minHeight: 560) {
        setup(commandLineTool: URL(filePath: "/usr/local/bin/lil"))
      },
      CatalogState("Connect an agent: without lil", minHeight: 560) {
        setup(commandLineTool: nil)
      },

      // The remote agents (851-2853), on their own, tall enough to see them all, with the row
      // opening their log.
      CatalogState("Remote agents", minHeight: 720) {
        remote(ConnectedAgentsFeature.State(agents: .loaded(remoteAgents), log: remoteReads))
      },
      CatalogState("Remote agents: none", minHeight: 720) {
        remote(ConnectedAgentsFeature.State(agents: .loaded([])))
      },
      CatalogState("Remote agents: loading", minHeight: 720) {
        remote(ConnectedAgentsFeature.State(agents: .loading, isLoadingLog: true))
      },
      CatalogState("Remote agents: failed", minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .failed(ConnectedAgentsError.unavailable.message),
            logFailure: ConnectedAgentsError.unavailable.message))
      },
      CatalogState("Remote agents: revoking", minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .loaded(remoteAgents), log: remoteReads, revoking: ["grant-1"]))
      },
      CatalogState("Remote agents: revoke failed", minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .loaded(remoteAgents), failure: ConnectedAgentsError.unavailable.message,
            log: remoteReads))
      },
      CatalogState("Remote agents: turning off", minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .loaded(remoteAgents), log: remoteReads, isTurningOff: true))
      },
      CatalogState("Remote agents: log loading", minHeight: 720) {
        remote(ConnectedAgentsFeature.State(agents: .loaded(remoteAgents), isLoadingLog: true))
      },
      CatalogState("Remote agents: log failed", minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .loaded(remoteAgents), logFailure: ConnectedAgentsError.unavailable.message))
      },
      CatalogState("Remote agents: long names", minHeight: 720) {
        remote(ConnectedAgentsFeature.State(agents: .loaded(longNamedAgents), log: remoteReads))
      },
      CatalogState("Remote agents: large window", width: largeWidth, minHeight: 720) {
        remote(
          ConnectedAgentsFeature.State(
            agents: .loaded(remoteAgents + longNamedAgents), log: remoteReads, logNextBefore: 94))
      },

      // The Agents pane's Access Log sheet (851-3082): the latest queries on this Mac, read again
      // while the pane is open, and Turn Off Access while access is on.
      CatalogState("Access log", width: sheetWidth, minHeight: sheetHeight) { accessLog() },
      CatalogState("Access log: off", width: sheetWidth, minHeight: sheetHeight) {
        accessLog(isEnabled: false)
      },
      CatalogState("Access log: empty", width: sheetWidth, minHeight: sheetHeight) {
        accessLog(entries: [])
      },
      CatalogState("Access log: loading", width: sheetWidth, minHeight: sheetHeight) {
        accessLog(isEnabled: false, entries: [], isLoading: true)
      },
      CatalogState("Access log: failed", width: sheetWidth, minHeight: sheetHeight) {
        accessLog(entries: [], logFailure: logUnreadable)
      },
      // The entries last read stay, with why they couldn't be read again below them.
      CatalogState("Access log: failed to read again", width: sheetWidth, minHeight: sheetHeight) {
        accessLog(logFailure: logUnreadable)
      },
      // The sheet resizes: its rows widen, and the commands show in full.
      CatalogState("Access log: resized", width: largeWidth, minHeight: largeHeight) {
        accessLog()
      },

      // The Remote Access Log sheet (851-3082), a page at a time. Those with something below the
      // reads are resized taller, to show it: at the size it opens at, it scrolls.
      CatalogState("Remote access log", width: sheetWidth, minHeight: sheetHeight) {
        remoteLog(ConnectedAgentsFeature.State(log: remoteReads))
      },
      CatalogState("Remote access log: empty", width: sheetWidth, minHeight: sheetHeight) {
        remoteLog(ConnectedAgentsFeature.State())
      },
      CatalogState("Remote access log: loading", width: sheetWidth, minHeight: sheetHeight) {
        remoteLog(ConnectedAgentsFeature.State(isLoadingLog: true))
      },
      CatalogState("Remote access log: failed", width: sheetWidth, minHeight: sheetHeight) {
        remoteLog(
          ConnectedAgentsFeature.State(logFailure: ConnectedAgentsError.unavailable.message))
      },
      CatalogState("Remote access log: more to read", width: sheetWidth, minHeight: tallSheetHeight)
      {
        remoteLog(ConnectedAgentsFeature.State(log: remoteReads, logNextBefore: 94))
      },
      CatalogState("Remote access log: reading more", width: sheetWidth, minHeight: tallSheetHeight)
      {
        remoteLog(
          ConnectedAgentsFeature.State(log: remoteReads, isLoadingLog: true, logNextBefore: 94))
      },
      CatalogState("Remote access log: more failed", width: sheetWidth, minHeight: tallSheetHeight)
      {
        remoteLog(
          ConnectedAgentsFeature.State(
            log: remoteReads, logFailure: ConnectedAgentsError.unavailable.message,
            logNextBefore: 94))
      },
      CatalogState("Remote access log: resized", width: largeWidth, minHeight: largeHeight) {
        remoteLog(ConnectedAgentsFeature.State(log: twoDaysOfReads, logNextBefore: 44))
      },
    ])

  /// A log's sheet, at the size it opens at.
  private let sheetWidth = AgentLogSheet<EmptyView, EmptyView>.idealWidth
  private let sheetHeight = AgentLogSheet<EmptyView, EmptyView>.idealHeight
  /// Tall enough for a page of reads and what's below it.
  private let tallSheetHeight: CGFloat = 600

  /// A large Settings window's panes: about as wide as a laptop's screen allows.
  private let largeWidth: CGFloat = 900
  private let largeHeight: CGFloat = 640

  // MARK: - Account

  @MainActor
  private func account(
    methods: SignInMethodsFeature.State.Methods = .loaded([
      SignInMethod(id: "idt_apple", provider: .apple, email: "x7y2@privaterelay.appleid.com")
    ]),
    export: DataExportFeature.State.Status = .idle,
    isSignedIn: Bool? = true
  ) -> some View {
    var state = AppFeature.State(isSignedIn: isSignedIn)
    state.account.signInMethods = SignInMethodsFeature.State(methods: methods)
    state.account.signInMethods.authorization.isGoogleAvailable = true
    state.account.signInMethods.authorization.appleWebAPI = URL(string: "https://api.lil.tech")
    state.account.dataExport.status = export
    return AccountSettingsView(store: Store(initialState: state) { EmptyReducer() })
      .settingsPaneFrame()
  }

  // MARK: - Agents

  /// The queries this Mac's agents made, newest first, with an intent's (851-2892).
  private let agentQueries = [
    AgentAccessEntry(
      id: 5, date: Date(timeIntervalSince1970: 1_760_973_000), command: "open Steps",
      process: "Shortcuts, Siri or Spotlight"),
    AgentAccessEntry(
      id: 4, date: Date(timeIntervalSince1970: 1_760_972_520), command: "metric Steps --range W",
      process: "claude"),
    AgentAccessEntry(
      id: 3, date: Date(timeIntervalSince1970: 1_760_972_460), command: "summary",
      process: "claude"),
    AgentAccessEntry(
      id: 2, date: Date(timeIntervalSince1970: 1_760_965_200),
      command: "samples HeartRate --from 2025-10-13 --to 2025-10-20", process: "Codex"),
    AgentAccessEntry(
      id: 1, date: Date(timeIntervalSince1970: 1_760_961_600), command: "sleep --json",
      process: "zsh"),
  ]

  @MainActor
  private func agents(
    isEnabled: Bool = true, entries: [AgentAccessEntry] = agentQueries, isLoading: Bool = false,
    failure: String? = nil, logFailure: String? = nil, isSignedIn: Bool? = true,
    commandLineTool: URL? = URL(filePath: "/usr/local/bin/lil")
  ) -> some View {
    var state = AppFeature.State(isSignedIn: isSignedIn)
    state.agentAccess = AgentAccessFeature.State(
      commandLineTool: commandLineTool, entries: entries, failure: failure, isEnabled: isEnabled,
      isLoading: isLoading, logFailure: logFailure)
    // The remote agents and their log, being read as the pane opens.
    state.connectedAgents = ConnectedAgentsFeature.State(agents: .loading, isLoadingLog: true)
    return AgentAccessSettingsView(store: Store(initialState: state) { EmptyReducer() })
      .settingsPaneFrame()
  }

  private let logUnreadable =
    "lil health couldn't read the access log: The database file is locked."

  @MainActor
  private func accessLog(
    isEnabled: Bool = true, entries: [AgentAccessEntry] = agentQueries, isLoading: Bool = false,
    logFailure: String? = nil
  ) -> some View {
    AgentAccessLogSheet(
      store: Store(
        initialState: AgentAccessFeature.State(
          entries: entries, isEnabled: isEnabled, isShowingLog: true, isLoading: isLoading,
          logFailure: logFailure)
      ) { EmptyReducer() })
  }

  @MainActor
  private func setup(commandLineTool: URL?) -> some View {
    Form {
      AgentSetupSection(commandLineTool: commandLineTool)
    }
    .formStyle(.grouped)
  }

  // MARK: - Remote agents

  /// Connected through the combined server, to every lil app (851-2902).
  private let combinedAgent = ConnectedAgent(
    id: "grant-5", name: "ChatGPT", domain: "chatgpt.com", app: nil, apps: ["health"],
    connectedAt: Date(timeIntervalSince1970: 1_760_960_000),
    firstUsedAt: nil,
    lastUsedAt: Date(timeIntervalSince1970: 1_760_960_000))

  /// Most recently connected first, as the API lists them. Last used 2 hours and 3 days before
  /// `previewNow`.
  private let remoteAgents = [
    combinedAgent,
    ConnectedAgent(
      id: "grant-1", name: "Claude", domain: "claude.ai", app: "health",
      connectedAt: Date(timeIntervalSince1970: 1_760_900_000),
      firstUsedAt: Date(timeIntervalSince1970: 1_760_900_060),
      lastUsedAt: previewNow.addingTimeInterval(-2 * 3600)),
    ConnectedAgent(
      id: "grant-2", name: "Weekly Health Digest", domain: nil, app: "health",
      connectedAt: Date(timeIntervalSince1970: 1_760_800_000),
      firstUsedAt: Date(timeIntervalSince1970: 1_760_800_060),
      lastUsedAt: previewNow.addingTimeInterval(-3 * 86_400)),
  ]

  /// An unverified agent with a name too long for its row, and an unnamed one.
  private let longNamedAgents = [
    ConnectedAgent(
      id: "grant-3",
      name: "A Very Long Agent Name That Somebody Registered For Their Own Health Dashboard",
      domain: nil, app: nil, apps: ["health"],
      connectedAt: Date(timeIntervalSince1970: 1_760_700_000),
      firstUsedAt: nil,
      lastUsedAt: Date(timeIntervalSince1970: 1_760_700_000)),
    ConnectedAgent(
      id: "grant-4", name: nil, domain: nil, app: "health",
      connectedAt: Date(timeIntervalSince1970: 1_760_600_000),
      firstUsedAt: nil,
      lastUsedAt: Date(timeIntervalSince1970: 1_760_600_000)),
  ]

  private let remoteReads = (1...6).map { index in
    RemoteAgentAccess(
      id: 100 - index, at: Date(timeIntervalSince1970: 1_760_972_520 - Double(index) * 1_800),
      agentID: index.isMultiple(of: 3) ? "grant-2" : "grant-1",
      agentName: index.isMultiple(of: 3) ? "Weekly Health Digest" : "Claude",
      tool: index.isMultiple(of: 2) ? "get_metric" : "summary",
      types: index.isMultiple(of: 2) ? ["HKQuantityTypeIdentifierStepCount"] : [],
      range: index.isMultiple(of: 2) ? "W" : nil, outcome: "ok", rows: 7)
  }

  /// Two days of reads, more than a page shows at first.
  private let twoDaysOfReads =
    remoteReads
    + remoteReads.map { read in
      var read = read
      read.id -= 50
      read.at = read.at.addingTimeInterval(-86_400)
      return read
    }

  @MainActor
  private func remoteLog(_ state: ConnectedAgentsFeature.State) -> some View {
    var state = state
    state.isShowingLog = true
    return RemoteAccessLogSheet(store: Store(initialState: state) { EmptyReducer() })
  }

  @MainActor
  private func remote(_ state: ConnectedAgentsFeature.State) -> some View {
    Form {
      ConnectedAgentsSections(store: Store(initialState: state) { EmptyReducer() })
    }
    .formStyle(.grouped)
  }
#endif
