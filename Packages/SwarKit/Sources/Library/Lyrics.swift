import Foundation

/// One sung word with an optional word-level timestamp (enhanced/A2 LRC).
public struct LyricsWord: Sendable, Equatable {
    public let time: TimeInterval?
    public let text: String

    public init(time: TimeInterval?, text: String) {
        self.time = time
        self.text = text
    }
}

/// One lyric line anchored to a playback timestamp. Lines without a real
/// timestamp (plain unsynchronised lyrics) use `time == -1` and never activate.
public struct LyricsLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let time: TimeInterval
    public let words: [LyricsWord]

    public var text: String { words.map(\.text).joined(separator: " ") }
    /// Instrumental breaks carry only a timestamp; Apple Music renders dots.
    public var displayText: String { words.isEmpty ? "•••" : text }
    public var isInstrumental: Bool { words.isEmpty }

    public init(id: Int, time: TimeInterval, words: [LyricsWord]) {
        self.id = id
        self.time = time
        self.words = words
    }
}

public struct TimedLyrics: Sendable, Equatable {
    public enum Source: String, Sendable {
        case embedded
        case sidecar
        case custom
    }

    public let source: Source
    public let lines: [LyricsLine]

    public init(source: Source, lines: [LyricsLine]) {
        self.source = source
        self.lines = lines
    }

    public func delayed(by seconds: Double) -> TimedLyrics {
        guard seconds.isFinite, seconds != 0, isSynced else { return self }
        return TimedLyrics(source: source, lines: lines.map { line in
            LyricsLine(id: line.id, time: max(0, line.time + seconds), words: line.words.map {
                LyricsWord(time: $0.time.map { max(0, $0 + seconds) }, text: $0.text)
            })
        })
    }

    /// False for plain unsynchronised lyrics, which render without highlighting.
    public var isSynced: Bool { lines.first.map { $0.time >= 0 } ?? false }
    public var isWordTimed: Bool { isSynced && lines.contains { $0.words.contains { $0.time != nil } } }

    /// Index of the line sung at `time`, or nil before the first line.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard isSynced, let first = lines.first, time >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Index of the last word in `lines[line]` whose timestamp has passed.
    public func wordIndex(line: Int, at time: TimeInterval) -> Int? {
        guard lines.indices.contains(line) else { return nil }
        var active: Int?
        for (index, word) in lines[line].words.enumerated() where word.time.map { $0 <= time } == true {
            active = index
        }
        return active
    }
}

/// Presentation clock that bridges the engine's polled position snapshots.
///
/// The engine publishes position at 250–400 ms intervals. Lyrics transitions
/// must not wait for the next snapshot, so the view extrapolates from the last
/// snapshot while playing. Extrapolation is capped so a playback stall or a
/// late snapshot can only ever run the clock a bounded distance ahead, and a
/// seek suspends extrapolation entirely until the engine confirms the target.
public struct LyricsPlaybackClock: Sendable, Equatable {
    public let position: TimeInterval
    public let date: Date
    public let playing: Bool
    public let seeking: Bool
    /// How far ahead of the last snapshot the clock may extrapolate.
    public let maximumExtrapolation: TimeInterval

    public init(position: TimeInterval, date: Date, playing: Bool, seeking: Bool,
                maximumExtrapolation: TimeInterval = 0.6) {
        self.position = position
        self.date = date
        self.playing = playing
        self.seeking = seeking
        self.maximumExtrapolation = maximumExtrapolation
    }

    public func displayPosition(at now: Date) -> TimeInterval {
        guard playing, !seeking else { return position }
        let elapsed = max(0, now.timeIntervalSince(date))
        guard elapsed.isFinite else { return position }
        return position + min(elapsed, maximumExtrapolation)
    }

    /// True when a new snapshot differs from the extrapolated clock enough to
    /// be a seek rather than ordinary progression between polls.
    public func isDiscontinuity(at newPosition: TimeInterval) -> Bool {
        abs(newPosition - displayPosition(at: Date())) > maximumExtrapolation
    }
}

/// Parses LRC text (embedded in a lyrics tag or stored as a `.lrc` sidecar).
///
/// Supported: `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, multiple timestamps per
/// line, `[offset:±ms]`, ignored metadata tags, and enhanced word tags
/// `<mm:ss.xx>` preceding each word. Timestamps are made non-decreasing;
/// positive `offset` shifts lyrics earlier (standard LRC convention).
public enum LyricsParser {
    private static let lineTimeTag = try! NSRegularExpression(
        pattern: #"^(\d+):(\d{1,2})(?:[.:](\d{1,3}))?$"#)
    private static let wordTimeTag = try! NSRegularExpression(
        pattern: #"<(\d+):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    public static func parse(_ raw: String, source: TimedLyrics.Source) -> TimedLyrics? {
        var offset: TimeInterval = 0
        var entries: [(time: TimeInterval, words: [LyricsWord], order: Int)] = []
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw

        for (order, line) in text.components(separatedBy: .newlines).enumerated() {
            var rest = Substring(line.trimmingCharacters(in: .whitespaces))
            guard rest.hasPrefix("[") else { continue }
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                if let stamp = timestamp(in: tag, pattern: lineTimeTag) {
                    stamps.append(stamp)
                } else if tag.lowercased().hasPrefix("offset"),
                          let milliseconds = Double(tag.dropFirst("offset".count)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "+: "))), milliseconds.isFinite {
                    offset = milliseconds / 1000
                }
                // Other metadata ([ti:], [ar:], [by:]…) is intentionally ignored.
            }
            guard !stamps.isEmpty else { continue }
            let words = enhancedWords(in: rest.trimmingCharacters(in: .whitespaces))
            for stamp in stamps {
                let shift = stamp - (stamps.first ?? stamp)
                let repeatedWords = words.map { LyricsWord(time: $0.time.map { $0 + shift }, text: $0.text) }
                entries.append((stamp, repeatedWords, order))
            }
        }

        guard !entries.isEmpty else { return nil }
        // Offset is file-wide, even when its tag follows the lyric lines.
        entries = entries.map { entry in
            (max(0, entry.time - offset),
             entry.words.map { LyricsWord(time: $0.time.map { max(0, $0 - offset) }, text: $0.text) }, entry.order)
        }
        entries.sort { lhs, rhs in
            lhs.time == rhs.time ? lhs.order < rhs.order : lhs.time < rhs.time
        }
        var lines: [LyricsLine] = []
        var lastTime: TimeInterval?
        for entry in entries {
            guard entry.time != lastTime else { continue }
            lastTime = entry.time
            lines.append(LyricsLine(id: lines.count, time: entry.time, words: entry.words))
        }
        return TimedLyrics(source: source, lines: lines)
    }

    /// Builds a non-synced model from plain lyric text so the view can still
    /// present unsynchronised lyrics instead of an empty state.
    public static func unsynced(_ raw: String, source: TimedLyrics.Source) -> TimedLyrics? {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return TimedLyrics(source: source, lines: lines.enumerated().map { index, text in
            LyricsLine(id: index, time: -1, words: [LyricsWord(time: nil, text: text)])
        })
    }

    /// Splits content into words, attaching each `<mm:ss.xx>` tag to the word
    /// that follows it (standard A2 enhanced-LRC layout). Words before the
    /// first tag carry no individual time.
    private static func enhancedWords(in content: String) -> [LyricsWord] {
        guard content.contains("<") else {
            return content.split(separator: " ", omittingEmptySubsequences: true)
                .map { LyricsWord(time: nil, text: String($0)) }
        }
        let string = String(content) as NSString
        var words: [LyricsWord] = []
        var pending: TimeInterval?
        var cursor = 0
        while cursor <= string.length,
              let match = wordTimeTag.firstMatch(in: string as String,
                                                 range: NSRange(location: cursor, length: string.length - cursor)) {
            if match.range.location > cursor {
                let text = string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                for token in text.split(separator: " ", omittingEmptySubsequences: true) {
                    words.append(LyricsWord(time: pending, text: String(token)))
                    pending = nil
                }
            }
            if let stamp = timestamp(in: string.substring(with: match.range), pattern: wordTimeTag) {
                pending = stamp
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < string.length {
            let tail = string.substring(with: NSRange(location: cursor, length: string.length - cursor))
            for token in tail.split(separator: " ", omittingEmptySubsequences: true) {
                words.append(LyricsWord(time: pending, text: String(token)))
                pending = nil
            }
        }
        return words
    }

    private static func timestamp(in tag: String, pattern: NSRegularExpression) -> TimeInterval? {
        guard let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              match.range.location != NSNotFound else { return nil }
        let value = { (group: Int) -> String? in
            guard let range = Range(match.range(at: group), in: tag) else { return nil }
            return String(tag[range])
        }
        guard let minutes = value(1).flatMap(Double.init),
              let seconds = value(2).flatMap(Double.init), seconds < 60 else { return nil }
        var stamp = minutes * 60 + seconds
        if let fraction = value(3) {
            // 2 digits are centiseconds, 3 digits are milliseconds.
            let divisor = pow(10, Double(fraction.count))
            stamp += (Double(fraction) ?? 0) / divisor
        }
        return stamp.isFinite ? stamp : nil
    }
}
