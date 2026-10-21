#if os(macOS)
  import Darwin
  public import Foundation

  extension AgentAccessStore {
    /// The name of the process that started this one, for the log: the shell a command ran in,
    /// or the agent that launched an MCP server (`claude`, `Codex`…). `nil` if it can't be told,
    /// such as when that process has already quit.
    public static func callingProcess(of pid: pid_t = getppid()) -> String? {
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      let executable = String(
        decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return URL(filePath: executable).lastPathComponent
    }
  }
#endif
