import SwiftUI
import Library
import Player

/// Apple Music-style lyrics: the active line is large and lit, past and future
/// lines are dimmed, the view keeps the active line centred, and tapping a line
/// seeks to it. Songs with enhanced (word-timed) LRC sweep the highlight
/// through the active line word by word.
@MainActor
struct LyricsView: View {
    let player: Player
    let library: LibraryModel
    var compact = false

    @Environment(\.swarPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyrics: TimedLyrics?
    @State private var loadedURL: URL?
    /// Local playback clock: advances between position refreshes, snapped to
    /// the player's position on every refresh so it never drifts.
    @State private var clock: Double = 0
    @State private var userScrollPaused = false

    private static let lineID = { (line: LyricsLine) -> String in "lyric-\(line.id)" }

    var body: some View {
        Group {
            if let lyrics, !lyrics.lines.isEmpty {
                panel(lyrics)
            } else {
                empty
            }
        }
        .task(id: player.currentURL) { await load() }
        .task(id: player.isPlaying) {
            guard player.isPlaying else { return }
            while player.isPlaying && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled { clock = min(clock + 0.1, max(0, player.duration)) }
            }
        }
        .onChange(of: player.position) { clock = player.position }
        .onChange(of: player.currentURL) { clock = player.position }
    }

    private func load() async {
        let url = player.currentURL
        loadedURL = url
        lyrics = await library.lyrics(for: url ?? URL(fileURLWithPath: "/"))
        if loadedURL == url { clock = player.position }
    }

    // MARK: - Layout

    private func panel(_ lyrics: TimedLyrics) -> some View {
        let active = lyrics.isSynced ? lyrics.lineIndex(at: clock) : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 16 : 20) {
                    Color.clear.frame(height: compact ? 60 : 110).accessibilityHidden(true)
                    ForEach(lyrics.lines) { line in
                        lyricLine(line, lyrics: lyrics, active: active)
                            .id(Self.lineID(line))
                    }
                    Color.clear.frame(height: compact ? 60 : 110).accessibilityHidden(true)
                }
                .padding(.horizontal, compact ? 16 : 24)
            }
            .scrollIndicators(.never)
            .mask(fadeMask)
            .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { _ in
                if !userScrollPaused { userScrollPaused = true }
            })
            .onChange(of: active) { _, newValue in
                guard let id = newValue, !userScrollPaused, !reduceMotion else { return }
                withAnimation(.spring(duration: 0.45)) { proxy.scrollTo(Self.lineID(lyrics.lines[id]), anchor: .center) }
            }
            .task(id: userScrollPaused) {
                guard userScrollPaused else { return }
                try? await Task.sleep(for: .seconds(4))
                userScrollPaused = false
            }
        }
        .accessibilityLabel("Lyrics")
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricsLine, lyrics: TimedLyrics, active: Int?) -> some View {
        let isActive = active == line.id
        let content = Group {
            if isActive, lyrics.isWordTimed { sweepingLine(line) } else { Text(line.displayText) }
        }
        Button {
            guard line.time >= 0 else { return }
            userScrollPaused = true
            Task { await player.seek(to: line.time) }
        } label: {
            content
                .font(.system(size: lineFontSize(active: isActive), weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.38))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.time < 0)
        .accessibilityLabel(line.isInstrumental ? "Instrumental" : line.text)
        .accessibilityHint(line.time >= 0 ? "Plays from \(Self.timestamp(line.time))" : "")
        .help(line.time >= 0 ? "Seek to \(Self.timestamp(line.time))" : line.displayText)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: active)
    }

    /// Word-by-word sweep: sung words are lit, upcoming words stay dimmed.
    private func sweepingLine(_ line: LyricsLine) -> some View {
        var attributed = AttributedString()
        for (index, word) in line.words.enumerated() {
            if index > 0 { attributed += AttributedString(" ") }
            var piece = AttributedString(word.text)
            let sung = isSung(line: line, word: index)
            piece.foregroundColor = sung ? Color.primary : Color.primary.opacity(0.38)
            attributed += piece
        }
        return Text(attributed)
    }

    private func isSung(line: LyricsLine, word: Int) -> Bool {
        guard let time = line.words[word].time else { return true }
        return time <= clock
    }

    private func lineFontSize(active: Bool) -> CGFloat {
        guard !compact else { return active ? 19 : 16 }
        return active ? 26 : 21
    }

    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.9),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Lyrics", systemImage: "quote.bubble")
        } description: {
            Text("Lyrics appear when a song has an embedded lyrics tag or a matching .lrc file in its folder.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
