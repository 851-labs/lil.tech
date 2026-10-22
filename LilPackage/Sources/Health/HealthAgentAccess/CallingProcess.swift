#if os(macOS)
  import Darwin
  public import Foundation

  extension AgentAccessStore {
    /// The environment variable that names the calling process for the log when a process in
    /// between started this one: `lil mcp` sets it to `claude (via lil mcp)` for the servers it
    /// starts (851-2897), whose parent is `lil`. It's for the log only, like the rest of the log,
    /// not a security boundary: any process can set it.
    public static let callingProcessVariable = "LIL_CALLING_PROCESS"

    /// The name of the process that started this one, for the log: the shell a command ran in,
    /// or the agent that launched an MCP server (`claude`, `Codex`…), or the name
    /// `LIL_CALLING_PROCESS` gives, when it's set. `nil` if it can't be told, such as when that
    /// process has already quit.
    public static func callingProcess(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
      if let name = environment[callingProcessVariable], !name.isEmpty {
        return name
      }
      return callingProcess(of: getppid())
    }

    /// The name of the process with this ID's executable.
    public static func callingProcess(of pid: pid_t) -> String? {
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      let executable = String(
        decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return URL(filePath: executable).lastPathComponent
    }
  }
#endif
