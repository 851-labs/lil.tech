import LilSync
import SwiftUI

/// The sidebar's footer: how sync is doing. The account is in Settings (⌘,) and Sign Out in the
/// app menu (851-2822).
struct SyncFooterView: View {
  let status: SyncStatus
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      icon
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.callout)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if case .bootstrapping(let downloaded, let total) = status, total > 0 {
          ProgressView(value: Double(downloaded), total: Double(total))
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

  private var title: String {
    switch status {
    case .idle, .syncing: "Syncing…"
    case .bootstrapping: "Downloading your data…"
    case .upToDate: "Up to date"
    case .offline: "Offline"
    case .failed: "Couldn't sync"
    }
  }

  private var detail: String? {
    switch status {
    case .idle, .syncing:
      nil
    case .bootstrapping(let downloaded, let total):
      total > 0 ? "\(downloaded) of \(total) parts" : nil
    case .upToDate(let date):
      "Updated \(date.formatted(.relative(presentation: .named)))"
    case .offline:
      "Syncs when you're back online"
    case .failed:
      "Trying again shortly"
    }
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

#Preview("Downloading") {
  footer(.bootstrapping(downloadedParts: 12, totalParts: 80))
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
