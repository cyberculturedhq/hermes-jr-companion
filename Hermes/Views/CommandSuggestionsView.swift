import SwiftUI

/// A standard iOS list attached to the composer. Selecting a row only edits the draft.
struct CommandSuggestionsView: View {
    let suggestions: [HermesCommandSuggestion]
    let isLoading: Bool
    let error: String?
    let hint: String?
    let select: (HermesCommandSuggestion) -> Void
    let retry: () -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight = 68.0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List {
                Section("Commands") {
                    ForEach(suggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.display)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !suggestion.description.isEmpty {
                                    Text(suggestion.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("command.\(suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    if suggestions.isEmpty {
                        if isLoading {
                            ProgressView("Loading commands…")
                        } else if let error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                Button("Try Again", action: retry)
                            }
                        } else {
                            Text(hint ?? "No matching commands")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.never)
            .frame(height: min(rowHeight * 3.5 + 36, rowHeight * Double(max(1, suggestions.count)) + 36))
            .accessibilityIdentifier("chat.commands")
        }
        // Plain-list section headers are transparent. Back the entire popup,
        // including its header and empty states, while it overlays the transcript.
        .background(Color(uiColor: .systemBackground))
    }
}
