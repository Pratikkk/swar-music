import SwiftUI
import Library

struct RecentLibrarySearch: Codable, Equatable {
    let query: String
    let scope: String

    static func recording(_ query: String, scope: TrackSearchScope, in history: [Self]) -> [Self] {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !TrackSearchQuery(trimmed).isEmpty else { return history }
        let entry = Self(query: trimmed, scope: scope.rawValue)
        let remaining = history.filter {
            $0.scope != entry.scope || $0.query.caseInsensitiveCompare(trimmed) != .orderedSame
        }
        return Array(([entry] + remaining).prefix(8))
    }
}

/// Search-only state stays outside the library and playback view hierarchy.
@MainActor
struct LibrarySearchField: View {
    @Environment(\.swarPalette) private var palette
    @Binding var query: String
    @Binding var scope: TrackSearchScope
    @FocusState.Binding var focused: Bool
    let section: String
    let availableWidth: CGFloat
    @AppStorage("recentLibrarySearches") private var historyData = ""

    private var history: [RecentLibrarySearch] {
        guard let data = historyData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentLibrarySearch].self, from: data) else { return [] }
        return Array(decoded.filter { !$0.query.isEmpty && TrackSearchScope(rawValue: $0.scope) != nil }.prefix(8))
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Search In", selection: $scope) {
                    ForEach(TrackSearchScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    if scope != .all { Text(scope.rawValue).font(.caption).lineLimit(1) }
                }
                .foregroundStyle(scope == .all ? Color.secondary : palette.accent)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Search field: " + scope.rawValue)
            .help("Choose which music details to search")

            TextField(scope == .all ? "Find in \(section)" : "Search \(scope.rawValue)", text: $query)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityLabel("Search " + scope.rawValue)
                .help("Results update as you type. Match the beginning of words; use several words to narrow results.")
                .onSubmit { remember() }
                .onKeyPress(.escape) {
                    if query.isEmpty { focused = false }
                    else { query = "" }
                    return .handled
                }
            if !query.isEmpty {
                Button { query = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Clear search").help("Clear search (Escape)")
            } else if !history.isEmpty {
                Menu {
                    Section("Recent Searches") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, item in
                            Button {
                                scope = TrackSearchScope(rawValue: item.scope) ?? .all
                                query = item.query
                                remember()
                                focused = true
                            } label: {
                                Text(item.query + (item.scope == TrackSearchScope.all.rawValue ? "" : " · " + item.scope))
                            }
                        }
                    }
                    Divider()
                    Button("Clear Recent Searches", role: .destructive) { historyData = "" }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Recent searches").help("Recent searches")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 12)
        .frame(width: min(max(180, availableWidth - 110), focused || !query.isEmpty || scope != .all ? 330 : 210), height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? palette.accent.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 0.5))
        .onChange(of: focused) { if !focused { remember() } }
    }

    private func remember() {
        let updated = RecentLibrarySearch.recording(query, scope: scope, in: history)
        guard updated != history, let data = try? JSONEncoder().encode(updated),
              let text = String(data: data, encoding: .utf8) else { return }
        historyData = text
    }
}
