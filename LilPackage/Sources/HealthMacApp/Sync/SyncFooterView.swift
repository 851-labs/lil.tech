import HealthUI
import LilSync
import SwiftUI

/// The sidebar's footer: how sync is doing. The account is in Settings (⌘,) and Sign Out in the
/// app menu (851-2822).
struct SyncFooterView: View {
  let status: SyncStatus
  let retry: () -> Void

  var body: some View {
    let content = SyncFooterContent(status)
    HStack(alignment: .center, spacing: 8) {
      icon
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(content.title)
          .font(.callout)
        if let detail = content.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        switch content.bar {
        case .none:
          EmptyView()
        case .indeterminate:
          ProgressView()
            .progressViewStyle(.linear)
            .controlSize(.small)
        case .determinate(let done, let total):
          ProgressView(value: Double(done), total: Double(total))
            .controlSize(.small)
        }
      }
      Spacer(minLength: 0)
      switch status {
      case .failed, .offline:
        // Without waiting out the backoff, e.g. once the connection is back.
        Button("Try Again", action: retry)
          .controlSize(.small)
      default:
        EmptyView()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // All of it takes clicks, so none reach a sidebar row scrolled under it.
    .contentShape(Rectangle())
  }

  @ViewBuilder private var icon: some View {
    switch status {
    case .idle, .syncing, .bootstrapping:
      ProgressView()
        .controlSize(.small)
    case .upToDate:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .offline:
      Image(systemName: "wifi.slash")
        .foregroundStyle(.secondary)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
    }
  }
}

/// What the footer says about a status. A first sync counts records left in each stage, in the
/// iPhone's words ("1,234,567 items left", `ItemsCopy`), and its bar is never full while work
/// goes on: the final transaction, which can't report progress, says "Finishing up…" over a
/// moving bar (851-2946).
struct SyncFooterContent: Equatable {
  enum Bar: Equatable {
    case none
    case indeterminate
    case determinate(done: Int, total: Int)
  }

  var title: String
  var detail: String?
  var bar: Bar

  init(_ status: SyncStatus) {
    switch status {
    case .idle:
      self.init(title: "Syncing…", detail: nil, bar: .none)
    case .syncing(let cursor, let head):
      // A catch-up of more than a page, such as the changes since a snapshot. Everyday syncs
      // are one page, and go straight to up to date. No bar: where it started isn't known.
      self.init(
        title: "Syncing…", detail: head > cursor ? ItemsCopy.left(head - cursor) : nil,
        bar: .none)
    case .bootstrapping(let progress):
      switch progress.stage {
      case .downloading:
        self.init(title: "Downloading your data…", progress: progress)
      case .loading:
        self.init(title: "Saving to this Mac…", progress: progress)
      case .finishing:
        self.init(title: "Finishing up…", detail: nil, bar: .indeterminate)
      }
    case .upToDate(let date):
      self.init(
        title: "Up to date",
        detail: "Updated \(date.formatted(.relative(presentation: .named)))", bar: .none)
    case .offline:
      self.init(title: "Offline", detail: "Syncs when you're back online", bar: .none)
    case .failed:
      self.init(title: "Couldn't sync", detail: "Trying again shortly", bar: .none)
    }
  }

  init(title: String, detail: String?, bar: Bar) {
    self.title = title
    self.detail = detail
    self.bar = bar
  }

  /// Records left, once the snapshot's manifest has said how many there are.
  private init(title: String, progress: BootstrapProgress) {
    guard progress.totalRecords > 0 else {
      self.init(title: title, detail: nil, bar: .indeterminate)
      return
    }
    self.init(
      title: title, detail: ItemsCopy.left(progress.recordsLeft),
      bar: .determinate(
        done: min(progress.records, progress.totalRecords), total: progress.totalRecords))
  }
}

@MainActor
private func footer(_ status: SyncStatus) -> some View {
  SyncFooterView(status: status, retry: {})
    .frame(width: 260)
    .background(.background)
}

#Preview("Syncing") {
  footer(.syncing(cursor: 1_200, head: 9_000))
}

// Catching up on the changes since the snapshot, after a first sync.
#Preview("Catching up, many changes") {
  footer(.syncing(cursor: 2_000_000, head: 2_487_650))
}

#Preview("Downloading, starting") {
  footer(.bootstrapping(.downloading(0, of: 0)))
}

#Preview("Downloading") {
  footer(.bootstrapping(.downloading(300_000, of: 2_000_000)))
}

#Preview("Downloading, very large") {
  footer(.bootstrapping(.downloading(1_250_000, of: 48_731_204)))
}

// Every part downloaded: the count starts again for saving them, rather than sitting at zero.
#Preview("Downloaded, saving starts") {
  footer(.bootstrapping(.loading(0, of: 2_000_000)))
}

#Preview("Saving") {
  footer(.bootstrapping(.loading(1_385_000, of: 2_000_000)))
}

#Preview("Saving, one left") {
  footer(.bootstrapping(.loading(1_999_999, of: 2_000_000)))
}

#Preview("Finishing up") {
  footer(.bootstrapping(.finishing(2_000_000)))
}

#Preview("Up to date") {
  footer(.upToDate(at: .now.addingTimeInterval(-120)))
}

#Preview("Offline") {
  footer(.offline)
}

#Preview("Failed") {
  footer(.failed("unexpectedStatus(500)"))
}
