import Foundation
import HealthDatabase
import LilUI
import SQLiteData
public import SwiftUI

/// Health Documents (CDA), newest first, as Health lists them: each its title, who it's from and
/// its date, opening the document. Follows the local database as sync changes it.
public struct HealthDocumentsView: View {
  @Fetch private var documents: [HealthDocument]

  public init() {
    _documents = Fetch(wrappedValue: [], RecentHealthDocuments(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    HealthDocumentsContent(
      state: $documents.loadError.map { .failed($0.localizedDescription) }
        ?? ($documents.isLoading && documents.isEmpty ? .loading : .loaded(documents)))
  }
}

/// The most recent documents: people have a handful, a few a year from each provider.
struct RecentHealthDocuments: FetchKeyRequest {
  static let limit = 500

  func fetch(_ db: Database) throws -> [HealthDocument] {
    try HealthDatabase.healthDocuments(limit: Self.limit, db)
  }
}

/// What the document list shows, however it got it.
struct HealthDocumentsContent: View {
  enum State {
    case loading
    case loaded([HealthDocument])
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let state: State
  /// How many the list holds at most (`RecentHealthDocuments.limit`), to say when it's full.
  var limit = RecentHealthDocuments.limit

  var body: some View {
    Group {
      switch state {
      case .loading:
        // Its space, under the spinner `delayedProgress` shows (851-3086).
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Health Documents", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let documents) where documents.isEmpty:
        ContentUnavailableView(
          "No Health Documents", systemImage: "doc.text",
          description: Text(
            "Visit summaries and other documents from your health providers will appear here."))
      case .loaded(let documents):
        list(documents)
      }
    }
    .delayedProgress(isLoading: state.isLoading)
    .navigationTitle("Health Documents")
  }

  /// One section, in a grouped list (`LazyGroupedList`): a `Form` builds every row at once, and
  /// the list holds up to 500.
  private func list(_ documents: [HealthDocument]) -> some View {
    LazyGroupedList {
      Section {
        ForEach(documents) { document in
          NavigationLink {
            HealthDocumentDetailView(document: document)
          } label: {
            HealthDocumentRow(document: document)
          }
        }
      } footer: {
        if documents.count >= limit {
          Text("Showing the \(limit.formatted()) most recent documents.")
        }
      }
    }
  }
}

/// A document in the list: its title, who it's from, and its date.
struct HealthDocumentRow: View {
  let document: HealthDocument

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "doc.text")
        .font(.title3)
        .foregroundStyle(.blue)
        .frame(width: 36, height: 36)
        .background(.blue.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(document.displayTitle)
          .font(.headline)
        if let byline = document.byline {
          Text(byline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(document.start.formatted(date: .abbreviated, time: .omitted))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

extension HealthDocument {
  /// Its title, or a generic one if HealthKit found none.
  var displayTitle: String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Health Document" : title
  }
}
