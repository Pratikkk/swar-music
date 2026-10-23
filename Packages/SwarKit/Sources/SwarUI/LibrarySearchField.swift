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
    let library: LibraryModel
    let openSuggestion: (LibrarySearchSuggestion) -> Void
    @State private var suggestions: [LibrarySearchSuggestion] = []
    @State private var highlighted: Int?
    @State private var dismissed = false
    let section: String
    let availableWidth: CGFloat
    @AppStorage("recentLibrarySearches") private var historyData = ""

    private var history: [RecentLibrarySearch] {
        guard let data = historyData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentLibrarySearch].self, from: data) else { return [] }
        return Array(decoded.filter { !$0.query.isEmpty && TrackSearchScope(rawValue: $0.scope) != nil }.prefix(8))
    }

    private var showsSuggestions: Bool { focused && !dismissed && !suggestions.isEmpty }

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
                .onSubmit {
                    remember()
                    if showsSuggestions, let highlighted, suggestions.indices.contains(highlighted) {
                        activate(suggestions[highlighted])
                    } else { dismissed = true }
                }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    dismissed = false
                    highlighted = min((highlighted ?? -1) + 1, suggestions.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showsSuggestions else { return .ignored }
                    highlighted = max(0, (highlighted ?? suggestions.count) - 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if showsSuggestions { dismissed = true; highlighted = nil }
                    else if query.isEmpty { focused = false }
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
        .overlay(alignment: .topTrailing) {
            if showsSuggestions {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { activate(suggestion) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: symbol(suggestion)).frame(width: 20)
                                    .foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(suggestion)).lineLimit(1)
                                    Text(subtitle(suggestion)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if highlighted == index { Image(systemName: "return").foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .background(highlighted == index ? palette.accent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).id(index)
                        .accessibilityLabel(title(suggestion) + ", " + subtitle(suggestion))
                    }
                        }.padding(6)
                    }
                    .frame(height: min(360, CGFloat(suggestions.count) * 48 + 12))
                    .onChange(of: highlighted) {
                        if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
                    }
                }
                .frame(width: min(380, max(220, availableWidth - 48)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                .offset(y: 38)
            }
        }
        .task(id: "\(focused)-\(query)-\(scope)-\(library.trackActionsRevision)-\(library.isReady)") {
            suggestions = []; highlighted = nil; dismissed = false
            guard focused, !TrackSearchQuery(query).isEmpty else { return }
            let text = query, field = scope
            do {
                try await Task.sleep(for: .milliseconds(150))
                let results = try await library.searchSuggestions(for: text, scope: field)
                guard !Task.isCancelled, text == query, field == scope, focused else { return }
                suggestions = results
            } catch { /* Cancellation or an unavailable index leaves normal search usable. */ }
        }
        .onChange(of: focused) { if !focused { remember() } }
    }

    private func activate(_ suggestion: LibrarySearchSuggestion) {
        remember(); dismissed = true; focused = false
        openSuggestion(suggestion)
    }

    private func title(_ suggestion: LibrarySearchSuggestion) -> String {
        switch suggestion {
        case .artist(let name): name
        case .album(let title, _): title
        case .song(let track): track.title
        }
    }
    private func subtitle(_ suggestion: LibrarySearchSuggestion) -> String {
        switch suggestion {
        case .artist: "Artist"
        case .album(_, let artist): "Album · " + artist
        case .song(let track): "Play song · " + track.artist
        }
    }
    private func symbol(_ suggestion: LibrarySearchSuggestion) -> String {
        switch suggestion {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .song: "play.fill"
        }
    }

    private func remember() {
        let updated = RecentLibrarySearch.recording(query, scope: scope, in: history)
        guard updated != history, let data = try? JSONEncoder().encode(updated),
              let text = String(data: data, encoding: .utf8) else { return }
        historyData = text
    }
}
