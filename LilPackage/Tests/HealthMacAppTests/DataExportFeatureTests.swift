import ComposableArchitecture
import Foundation
import LilAuth
import Testing

@testable import HealthMacApp

// Synthetic data only (AGENTS.md).
@MainActor
struct DataExportFeatureTests {
  private let archive = URL(string: "https://api.lil.tech/v1/exports/download?token=t")!
  private let file = URL(filePath: "/tmp/export-download")
  private let saved = URL(filePath: "/Users/ada/Downloads/lil-export-2026-10-18.tar")

  @Test
  func waitsForTheExportThenDownloadsAndSavesIt() async {
    let polls = LockIsolated(0)
    let store = TestStore(initialState: DataExportFeature.State()) {
      DataExportFeature()
    } withDependencies: { [archive, file, saved] in
      $0.continuousClock = ImmediateClock()
      $0.dataExports.request = { () throws(DataExportError) in
        DataExport(requestedAt: Date(timeIntervalSince1970: 0), url: nil)
      }
      $0.dataExports.latest = { () throws(DataExportError) in
        // Ready on the second check.
        polls.withValue { $0 += 1 }
        return DataExport(
          requestedAt: Date(timeIntervalSince1970: 0), url: polls.value >= 2 ? archive : nil)
      }
      $0.dataExports.download = { url in
        #expect(url == archive)
        return AsyncThrowingStream {
          $0.yield(.progress(0.5))
          $0.yield(.finished(file: file, name: "lil-export-2026-10-18.tar"))
          $0.finish()
        }
      }
      $0.archiveSaver.save = { downloaded, name in
        #expect(downloaded == file)
        #expect(name == "lil-export-2026-10-18.tar")
        return saved
      }
    }

    await store.send(.exportButtonTapped) {
      $0.status = .preparing
    }
    await store.receive(\.prepared) {
      $0.status = .downloading(0)
    }
    await store.receive(\.downloadProgressed) {
      $0.status = .downloading(0.5)
    }
    await store.receive(\.downloaded) {
      $0.status = .saving
    }
    await store.receive(\.saved) {
      $0.status = .saved(saved)
    }
    #expect(polls.value == 2)
  }

  @Test
  func cancelingTheSavePanelLeavesNothing() async {
    let store = TestStore(initialState: DataExportFeature.State(status: .saving)) {
      DataExportFeature()
    } withDependencies: {
      $0.archiveSaver.save = { _, _ in nil }
    }

    await store.send(.downloaded(file: file, name: "lil-export.tar"))
    await store.receive(\.saved) {
      $0.status = .idle
    }
  }

  @Test
  func aFailedRequestSaysWhy() async {
    let store = TestStore(initialState: DataExportFeature.State()) {
      DataExportFeature()
    } withDependencies: {
      $0.dataExports.request = { () throws(DataExportError) in throw .unavailable }
    }

    await store.send(.exportButtonTapped) {
      $0.status = .preparing
    }
    await store.receive(\.failed) {
      $0.status = .failed(DataExportError.unavailable.message)
    }
  }

  @Test
  func givesUpOnAnExportThatNeverGetsReady() async {
    let store = TestStore(initialState: DataExportFeature.State()) {
      DataExportFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.dataExports.request = { () throws(DataExportError) in
        DataExport(requestedAt: .now, url: nil)
      }
      $0.dataExports.latest = { () throws(DataExportError) in
        DataExport(requestedAt: .now, url: nil)
      }
    }

    await store.send(.exportButtonTapped) {
      $0.status = .preparing
    }
    await store.receive(\.failed) {
      $0.status = .failed(
        "Preparing the export is taking longer than usual. Please try again later.")
    }
  }

  @Test
  func cancelingStopsTheExport() async {
    let clock = TestClock()
    let store = TestStore(initialState: DataExportFeature.State()) {
      DataExportFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.dataExports.request = { () throws(DataExportError) in
        DataExport(requestedAt: .now, url: nil)
      }
    }

    await store.send(.exportButtonTapped) {
      $0.status = .preparing
    }
    await store.send(.cancelButtonTapped) {
      $0.status = .idle
    }
  }
}
