import SwiftUI
import AppKit
import Library
import Player

/// Native lyrics presentation. Only the active phrase interpolates at display cadence;
/// the library and surrounding player continue observing the ordinary playback clock.
@MainActor
struct LyricsView: View {
    let player: Player
    let library: LibraryModel
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyrics: TimedLyrics?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var clockDate = Date()
    @State private var clockPosition = 0.0
    @State private var userScrollPaused = false
    @State private var interaction = 0

    var body: some View {
        Group {
            if let lyrics, !lyrics.lines.isEmpty { panel(lyrics) }
            else if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { empty }
        }
        .task(id: player.currentURL) { await load() }
        .onChange(of: player.position, initial: true) { synchronizeClock() }
        .onChange(of: player.isPlaying) { synchronizeClock() }
    }

    private func synchronizeClock() {
        clockPosition = player.position
        clockDate = Date()
    }

    private func load() async {
        let request = UUID()
        requestID = request
        lyrics = nil
        userScrollPaused = false
        loading = true
        guard let url = player.currentURL else { loading = false; return }
        let result = await library.lyrics(for: url)
        guard !Task.isCancelled, requestID == request, player.currentURL == url else { return }
        lyrics = result
        loading = false
        synchronizeClock()
    }

    private func pauseFollowing() {
        userScrollPaused = true
        interaction &+= 1
    }

    private func panel(_ lyrics: TimedLyrics) -> some View {
        let active = lyrics.isSynced ? lyrics.lineIndex(at: player.position) : nil
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 18 : 24) {
                        Color.clear.frame(height: geometry.size.height * 0.32).accessibilityHidden(true)
                        ForEach(lyrics.lines) { line in
                            lyricLine(line, lyrics: lyrics, active: active)
                                .id(line.id)
                        }
                        Color.clear.frame(height: geometry.size.height * 0.5).accessibilityHidden(true)
                    }
                    .padding(.horizontal, compact ? 16 : 24)
                }
                .scrollIndicators(.never)
                .mask(fadeMask)
                .background(LyricsScrollObserver(onScroll: pauseFollowing))
                .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { _ in pauseFollowing() })
                .onChange(of: active, initial: true) { _, _ in follow(active, proxy: proxy) }
                .onChange(of: userScrollPaused) { _, paused in
                    if !paused { follow(active, proxy: proxy) }
                }
                .task(id: interaction) {
                    guard userScrollPaused else { return }
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard !Task.isCancelled else { return }
                    userScrollPaused = false
                }
            }
        }
        .accessibilityLabel("Lyrics")
    }

    private func follow(_ active: Int?, proxy: ScrollViewProxy) {
        guard let active, !userScrollPaused else { return }
        if reduceMotion { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.35)) }
        else {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.86)) {
                proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    private func lyricLine(_ line: LyricsLine, lyrics: TimedLyrics, active: Int?) -> some View {
        let selected = active == line.id
        let distance = active.map { abs(line.id - $0) } ?? 0
        let readable = !lyrics.isSynced || userScrollPaused
        return Button {
            guard line.time >= 0 else { return }
            userScrollPaused = false
            Task { await player.seek(to: line.time) }
        } label: {
            Group {
                if selected, lyrics.isWordTimed, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { context in
                        let position = min(player.duration, clockPosition + (player.isPlaying ? max(0, context.date.timeIntervalSince(clockDate)) : 0))
                        LyricsSweepingPhrase(line: line,
                            end: line.id + 1 < lyrics.lines.count ? lyrics.lines[line.id + 1].time : player.duration,
                            position: position)
                    }
                } else { Text(line.displayText) }
            }
            // A fixed font prevents rewrapping and scroll jumps on active-line changes.
            .font(.system(size: compact ? 19 : 26, weight: .bold))
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(selected || readable ? 1 : (distance <= 1 ? 0.5 : 0.3))
            .scaleEffect(selected || readable || reduceMotion ? 1 : 0.96, anchor: .leading)
            .blur(radius: readable || selected || reduceMotion ? 0 : (distance > 1 ? 1.2 : 0.35))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.time < 0)
        .accessibilityLabel(line.isInstrumental ? "Instrumental" : line.text)
        .accessibilityHint(line.time >= 0 ? "Play from \(Self.timestamp(line.time))" : "")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: selected)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: distance)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: userScrollPaused)
    }

    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Lyrics", systemImage: "quote.bubble")
        } description: {
            Text("Lyrics appear when a song has an embedded lyrics tag or a matching .lrc file in its folder.")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Smooth word illumination without changing phrase geometry or relaying display ticks
/// through the whole lyrics panel. Word timestamps determine progress; no fabricated sync.
private struct LyricsSweepingPhrase: View {
    let line: LyricsLine
    let end: Double
    let position: Double

    var body: some View {
        var text = AttributedString()
        for (index, word) in line.words.enumerated() {
            if index > 0 { text += AttributedString(" ") }
            let next = line.words.dropFirst(index + 1).compactMap(\.time).first ?? end
            let start = word.time ?? line.time
            let progress = min(1, max(0, (position - start) / max(0.08, next - start)))
            var piece = AttributedString(word.text)
            piece.foregroundColor = Color.primary.opacity(0.4 + 0.6 * progress)
            text += piece
        }
        return Text(text)
    }
}

/// Observe scroll-wheel/trackpad input only inside this panel. Never consume the event.
private struct LyricsScrollObserver: NSViewRepresentable {
    let onScroll: @MainActor () -> Void
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var onScroll: (@MainActor () -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onScroll?()
                    }
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
