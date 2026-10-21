import Foundation
import Testing

@testable import LilCLIInstaller

/// Installs fake `lil`s, shell scripts that print their version, into a temporary directory.
struct CommandLineToolInstallerTests {
  let root: URL
  let bin: URL

  init() throws {
    root = URL.temporaryDirectory.appending(
      path: "LilCLIInstallerTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    bin = root.appending(path: "home/.local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func fakeLil(version: Int, at url: URL) throws -> URL {
    try script("[ \"$1\" = --version ] && echo 'lil \(version)'", at: url)
  }

  func script(_ body: String, at url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  var installed: URL { bin.appending(path: "lil") }

  @Test
  func decides() {
    typealias Installer = CommandLineToolInstaller
    #expect(Installer.decide(bundledVersion: 5, existing: .none) == .install)
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 4)) == .replace(version: 4))
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 5)) == .keep(version: 5))
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 6)) == .keep(version: 6))
    #expect(Installer.decide(bundledVersion: 5, existing: .other) == .leaveAlone)
  }

  @Test
  func installsCreatingTheDirectory() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))

    let outcome = try await CommandLineToolInstaller.install(bundled, into: bin)

    #expect(outcome == .installed(installed, replacedVersion: nil))
    #expect(try Data(contentsOf: installed) == Data(contentsOf: bundled))
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
    // A copy, not a link into the app, which could move.
    let type = try FileManager.default.attributesOfItem(atPath: installed.path)[.type]
    #expect(type as? FileAttributeType == .typeRegular)
  }

  @Test
  func replacesAnOlderLil() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    _ = try fakeLil(version: 4, at: installed)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .installed(installed, replacedVersion: 4)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test(arguments: [5, 6])
  func keepsTheSameOrANewerLil(version: Int) async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    _ = try fakeLil(version: version, at: installed)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .upToDate(installed, version: version)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: version))
  }

  @Test
  func leavesAnotherCommandAlone() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    let other = try script("echo 'Lilypond helper'", at: installed)
    let contents = try Data(contentsOf: other)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin) == .otherCommand(installed)
    )
    #expect(try Data(contentsOf: installed) == contents)
  }

  @Test
  func replacesABrokenLink() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: installed.path,
      withDestinationPath: root.appending(path: "Moved.app/Contents/MacOS/lil").path
    )

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .installed(installed, replacedVersion: nil)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test
  func refusesABundledToolThatDoesntRun() async throws {
    let bundled = try script("exit 1", at: root.appending(path: "app/lil"))

    await #expect(throws: CommandLineToolInstaller.Failure.self) {
      try await CommandLineToolInstaller.install(bundled, into: bin)
    }
    #expect(!FileManager.default.fileExists(atPath: installed.path))
  }

  @Test
  func decidesWhatRefreshingDoes() {
    typealias Installer = CommandLineToolInstaller
    for writable in [true, false] {
      // Never installs where there's no `lil`, never downgrades, never touches another command.
      #expect(Installer.refresh(bundledVersion: 5, existing: .none, writable: writable) == .none)
      #expect(
        Installer.refresh(bundledVersion: 5, existing: .lil(version: 5), writable: writable)
          == .none
      )
      #expect(
        Installer.refresh(bundledVersion: 5, existing: .lil(version: 6), writable: writable)
          == .none
      )
      #expect(Installer.refresh(bundledVersion: 5, existing: .other, writable: writable) == .none)
    }
    #expect(
      Installer.refresh(bundledVersion: 5, existing: .lil(version: 4), writable: true)
        == .replace(version: 4)
    )
    // Replacing it would ask for a password, so it's offered instead.
    #expect(
      Installer.refresh(bundledVersion: 5, existing: .lil(version: 4), writable: false)
        == .offer(version: 4)
    )
  }

  @Test
  func offersOncePerBundledVersion() {
    let outdated = CommandLineToolInstaller.Outdated(
      directory: bin,
      version: 4,
      bundledVersion: 5
    )
    #expect(CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: 0))
    #expect(CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: 4))
    #expect(!CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: 5))
    #expect(!CommandLineToolInstaller.shouldOffer(outdated, lastOfferedVersion: 6))
  }

  @Test
  func refreshReplacesAnOlderLilItCanWrite() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    _ = try fakeLil(version: 4, at: installed)

    let result = await CommandLineToolInstaller.refreshInstalled(bundled, in: [bin])

    #expect(result == .init(replaced: [installed], outdated: []))
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test
  func refreshOffersToReplaceAnOlderLilItCantWrite() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    let shared = root.appending(path: "usr/local/bin", directoryHint: .isDirectory)
    let sharedLil = try fakeLil(version: 3, at: shared.appending(path: "lil"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shared.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
    }
    _ = try fakeLil(version: 4, at: installed)

    let result = await CommandLineToolInstaller.refreshInstalled(bundled, in: [shared, bin])

    #expect(
      result
        == .init(
          replaced: [installed],
          outdated: [.init(directory: shared, version: 3, bundledVersion: 5)]
        )
    )
    #expect(CommandLineToolInstaller.existing(at: sharedLil) == .lil(version: 3))
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test
  func refreshLeavesTheRestAlone() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    let newer = root.appending(path: "newer", directoryHint: .isDirectory)
    _ = try fakeLil(version: 6, at: newer.appending(path: "lil"))
    let other = root.appending(path: "other", directoryHint: .isDirectory)
    let otherContents = try Data(
      contentsOf: script("echo 'Lilypond helper'", at: other.appending(path: "lil")))
    let empty = root.appending(path: "empty", directoryHint: .isDirectory)

    let result = await CommandLineToolInstaller.refreshInstalled(
      bundled, in: [newer, other, empty])

    #expect(result == .init())
    #expect(CommandLineToolInstaller.existing(at: newer.appending(path: "lil")) == .lil(version: 6))
    #expect(try Data(contentsOf: other.appending(path: "lil")) == otherContents)
    // It doesn't install where there was no `lil`.
    #expect(!FileManager.default.fileExists(atPath: empty.appending(path: "lil").path))
  }

  @Test
  func refreshDoesNothingWithoutAnInstalledLil() async throws {
    // A bundled tool that doesn't run: refreshing doesn't run it when nothing is installed.
    let bundled = try script("touch \"$0.ran\"", at: root.appending(path: "app/lil"))

    #expect(await CommandLineToolInstaller.refreshInstalled(bundled, in: [bin]) == .init())
    #expect(!FileManager.default.fileExists(atPath: bundled.path + ".ran"))
  }

  @Test
  func writabilityLooksAtTheClosestExistingDirectory() throws {
    #expect(CommandLineToolInstaller.isWritable(bin))
    #expect(!CommandLineToolInstaller.isWritable(URL(filePath: "/System/lil-tests/bin")))
  }
}
