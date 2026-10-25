import Testing
import Foundation
import SwiftUI
@testable import Library

struct LyricsTests {
    @Test func trailingOffsetShiftsLinesAndWordsTogether() {
        let lyrics = LyricsParser.parse("[00:10]<00:10>Hello <00:11>world\n[offset:+1000]", source: .sidecar)
        #expect(lyrics?.lines.first?.time == 9)
        #expect(lyrics?.lines.first?.words.map(\.time) == [9, 10])
    }

    @Test func repeatedEnhancedPhraseShiftsWordTimes() {
        let lyrics = LyricsParser.parse("[00:10][00:20]<00:10>Hello <00:11>world", source: .sidecar)
        #expect(lyrics?.lines.last?.time == 20)
        #expect(lyrics?.lines.last?.words.map(\.time) == [20, 21])
    }

    @Test func parsesTimestampVariantsAndSortsLines() {
        let lyrics = LyricsParser.parse("""
        [00:12.5] later
        [00:03] first
        [00:06.25] second
        [00:09.123] third
        """, source: .sidecar)
        let lines = lyrics?.lines ?? []
        #expect(lines.map(\.time) == [3, 6.25, 9.123, 12.5])
        #expect(lines.map(\.text) == ["first", "second", "third", "later"])
        #expect(lyrics?.source == .sidecar && lyrics?.isSynced == true)
        #expect(lyrics?.isWordTimed == false)
    }

    @Test func multipleTimestampsDuplicateOneLineAndOffsetsShiftEarlier() {
        let lyrics = LyricsParser.parse("""
        [offset:+1000]
        [00:10][00:20] chorus
        [00:05] verse
        """, source: .embedded)
        #expect(lyrics?.lines.map(\.time) == [4, 9, 19])
        #expect(lyrics?.lines.allSatisfy { $0.text == "chorus" || $0.text == "verse" } == true)
    }

    @Test func metadataTagsAndNonLyricLinesAreIgnored() {
        let lyrics = LyricsParser.parse("""
        [ti:Song Title]
        [ar:Artist]
        [by:Someone]
        plain text without tags
        [00:01.00] real line
        """, source: .sidecar)
        #expect(lyrics?.lines.map(\.text) == ["real line"])
    }

    @Test func instrumentalTimestampsRenderDotsAndRemainSeekable() {
        let lyrics = LyricsParser.parse("[00:01.00]\n[00:05.00] words", source: .sidecar)
        #expect(lyrics?.lines.first?.isInstrumental == true)
        #expect(lyrics?.lines.first?.displayText == "•••")
        #expect(lyrics?.lines.first?.time == 1)
    }

    @Test func enhancedWordTagsAttachToFollowingWords() {
        let lyrics = LyricsParser.parse("""
        [00:10.00] <00:10.00> Hello <00:11.00> bright <00:12.00> world
        """, source: .embedded)
        let line = lyrics?.lines.first
        #expect(lyrics?.isWordTimed == true)
        #expect(line?.words.map(\.text) == ["Hello", "bright", "world"])
        #expect(line?.words.map(\.time) == [10, 11, 12])
        #expect(lyrics?.wordIndex(line: 0, at: 10.5) == 0)
        #expect(lyrics?.wordIndex(line: 0, at: 11.5) == 1)
        #expect(lyrics?.wordIndex(line: 0, at: 12.9) == 2)
        #expect(lyrics?.wordIndex(line: 0, at: 9.9) == nil)
    }

    @Test func activeLineIndexHandlesBoundaries() {
        let lyrics = LyricsParser.parse("[00:05] a\n[00:10] b\n[00:15] c", source: .sidecar)!
        #expect(lyrics.lineIndex(at: 0) == nil)
        #expect(lyrics.lineIndex(at: 4.99) == nil)
        #expect(lyrics.lineIndex(at: 5) == 0)
        #expect(lyrics.lineIndex(at: 10) == 1)
        #expect(lyrics.lineIndex(at: 10.1) == 1)
        #expect(lyrics.lineIndex(at: 999) == 2)
    }

    @Test func plainTextFallsBackToUnsyncedModelThatNeverActivates() {
        let unsynced = LyricsParser.unsynced("First line\n\nSecond line", source: .embedded)
        #expect(unsynced?.lines.map(\.text) == ["First line", "Second line"])
        #expect(unsynced?.isSynced == false)
        #expect(unsynced?.lineIndex(at: 60) == nil)
        #expect(LyricsParser.parse("no timestamps here", source: .embedded) == nil)
        #expect(LyricsParser.unsynced("  \n \n", source: .embedded) == nil)
    }

    @Test func malformedAndExtremeInputIsBounded() {
        #expect(LyricsParser.parse("", source: .embedded) == nil)
        #expect(LyricsParser.parse("[99:99.99] out of range seconds", source: .embedded) == nil)
        #expect(LyricsParser.parse("[-1:00] negative", source: .embedded) == nil)
        let big = (0..<3000).map { String(format: "[%02d:%02d.00] line %d", $0 / 60, $0 % 60, $0) }.joined(separator: "\n")
        let parsed = LyricsParser.parse(big, source: .sidecar)
        #expect(parsed?.lines.count == 3000)
        #expect(parsed?.lines.last?.text == "line 2999")
    }

    @Test func crlfAndUnicodeAndDevanagariSurviveParsing() {
        let lyrics = LyricsParser.parse(
            "[00:01.00] हर हर महादेव\r\n[00:02.00] Café ☕ naïve — em-dash\r\n",
            source: .sidecar)
        #expect(lyrics?.lines.map(\.text) == ["हर हर महादेव", "Café ☕ naïve — em-dash"])
        #expect(lyrics?.lines.map(\.time) == [1, 2])
    }

    @Test func offsetVariantsNegativeUnsignedListedLastAndInvalid() {
        // Negative offset delays lyrics; the tag may trail the content lines.
        let delayed = LyricsParser.parse("[00:10] a\n[offset:-2000]", source: .sidecar)
        #expect(delayed?.lines.map(\.time) == [12])
        // A missing sign is treated as positive.
        let early = LyricsParser.parse("[offset:500]\n[00:10] a", source: .sidecar)
        #expect(early?.lines.map(\.time) == [9.5])
        // An offset that would precede zero clamps to zero.
        let clamped = LyricsParser.parse("[offset:60000]\n[00:10] a", source: .sidecar)
        #expect(clamped?.lines.map(\.time) == [0])
        // Invalid offsets are ignored entirely.
        let ignored = LyricsParser.parse("[offset:abc]\n[00:10] a", source: .sidecar)
        #expect(ignored?.lines.map(\.time) == [10])
    }

    @Test func closelySpacedLinesStayDistinctAndActivateInOrder() {
        let tight = LyricsParser.parse("[00:10.00] a\n[00:10.04] b", source: .sidecar)
        #expect(tight?.lines.map(\.time) == [10, 10.04])
        #expect(tight?.lineIndex(at: 10.02) == 0)
        #expect(tight?.lineIndex(at: 10.04) == 1)
    }

    @Test func identicalWordTimestampsStillIlluminateSequentially() {
        // Duplicate word stamps collapse to the 80 ms floor window rather than
        // a zero division; the second word still lights immediately after.
        let repeated = LyricsParser.parse("[00:10.00] <00:10.00> go <00:10.00> now", source: .embedded)
        #expect(repeated?.lines.first?.words.map(\.time) == [10, 10])
        #expect(repeated?.wordIndex(line: 0, at: 10.04) == 1)
    }

    // MARK: - Playback clock

    @Test func playbackClockExtrapolatesOnlyWhilePlaying() {
        let snapshot = Date()
        let playing = LyricsPlaybackClock(position: 10, date: snapshot, playing: true, seeking: false)
        #expect(playing.displayPosition(at: snapshot.addingTimeInterval(0.25)) == 10.25)
        // Capped so a stalled engine can only run the clock 0.6 s ahead.
        #expect(playing.displayPosition(at: snapshot.addingTimeInterval(30)) == 10.6)
        // Paused and seeking clocks never extrapolate.
        let paused = LyricsPlaybackClock(position: 10, date: snapshot, playing: false, seeking: false)
        #expect(paused.displayPosition(at: snapshot.addingTimeInterval(5)) == 10)
        let seeking = LyricsPlaybackClock(position: 10, date: snapshot, playing: true, seeking: true)
        #expect(seeking.displayPosition(at: snapshot.addingTimeInterval(5)) == 10)
        // A snapshot dated in the future clamps to the snapshot position.
        let drifted = LyricsPlaybackClock(position: 10, date: snapshot.addingTimeInterval(2), playing: true, seeking: false)
        #expect(drifted.displayPosition(at: snapshot) == 10)
    }

    @Test func playbackClockDetectsSeekSizedDiscontinuities() {
        let snapshot = Date()
        let clock = LyricsPlaybackClock(position: 100, date: snapshot, playing: true, seeking: false)
        // Ordinary progression between snapshots is not a discontinuity.
        #expect(!clock.isDiscontinuity(at: 100.3))
        #expect(!clock.isDiscontinuity(at: 99.7))
        // A seek-sized jump in either direction is.
        #expect(clock.isDiscontinuity(at: 130))
        #expect(clock.isDiscontinuity(at: 40))
        // While paused or seeking there is no extrapolation, so tolerance is tight.
        #expect(LyricsPlaybackClock(position: 100, date: snapshot, playing: false, seeking: false)
            .isDiscontinuity(at: 100.7))
    }

    /// Steady-state CPU budget for the presentation layer, measured (not asserted):
    /// the active-line lookup runs at 10 Hz and the word sweep rebuild at 60 Hz.
    @Test func reportsSteadyStatePresentationCosts() throws {
        let big = (0..<3000).map { String(format: "[%02d:%02d.00] lyric line number %d", $0 / 60, $0 % 60, $0) }
            .joined(separator: "\n")
        let lyrics = try #require(LyricsParser.parse(big, source: .sidecar))

        var clock = ContinuousClock()
        let lookups = 10_000
        let lookupStart = clock.now
        var sink = 0
        for index in 0..<lookups {
            sink &+= lyrics.lineIndex(at: Double(index % 200)) ?? 0
        }
        let lookupElapsed = clock.now - lookupStart
        #expect(sink >= 0)

        let words = (0..<12).map { LyricsWord(time: Double($0), text: "word\($0)") }
        let line = LyricsLine(id: 0, time: 0, words: words)
        let sweeps = 6_000
        let sweepStart = clock.now
        var length = 0
        for index in 0..<sweeps {
            var attributed = AttributedString()
            for (wordIndex, word) in line.words.enumerated() {
                if wordIndex > 0 { attributed += AttributedString(" ") }
                var piece = AttributedString(word.text)
                piece.foregroundColor = Color.white.opacity(word.time ?? 0 <= Double(index % 12) ? 1 : 0.4)
                attributed += piece
            }
            length += attributed.characters.count
        }
        let sweepElapsed = clock.now - sweepStart
        #expect(length > 0)

        let toMicroseconds: (ContinuousClock.Duration) -> Double = {
            Double($0.components.seconds) * 1e6 + Double($0.components.attoseconds) / 1e12
        }
        print(String(format: "lyrics steady state: %d line lookups in %.2f ms (%.2f µs/lookup); %d sweep rebuilds in %.1f ms (%.1f µs/rebuild at 60 Hz → %.2f%% of a core)",
                     lookups, toMicroseconds(lookupElapsed) / 1000, toMicroseconds(lookupElapsed) / Double(lookups),
                     sweeps, toMicroseconds(sweepElapsed) / 1000, toMicroseconds(sweepElapsed) / Double(sweeps),
                     toMicroseconds(sweepElapsed) / Double(sweeps) * 60 / 10_000))
    }
}

/// Exercises the full resolution path: watched folder scope, sidecar lookup
/// beside the audio file, and the bounds applied to untrusted lyric files.
@MainActor
struct LyricsIntegrationTests {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixture: URL { package.appendingPathComponent("Tests/DecodingTests/Fixtures/44100-16.wav") }
    private var codecs: URL { package.appendingPathComponent("Vendor/FFmpeg/lib") }

    @Test func sidecarBesideTheAudioResolvesWithWordTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixture, to: song)
        let sidecar = music.appendingPathComponent("song.lrc")
        try Data("[00:01.00] <00:01.00> हर <00:02.00> हर\r\n[00:03.00] महादेव".utf8).write(to: sidecar)

        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        try await model.addFolder(music)
        defer { model.shutdown() }
        #expect(model.tracks.count == 1)

        let lyrics = await model.lyrics(for: song)
        let lines = lyrics?.lines ?? []
        #expect(lyrics?.source == .sidecar)
        #expect(lyrics?.isWordTimed == true)
        #expect(lines.count == 2)
        #expect(lines.first?.words.map(\.text) == ["हर", "हर"])
        #expect(lines.first?.words.map(\.time) == [1, 2])
        #expect(lines.last?.text == "महादेव")
    }

    @Test func songWithoutAnyLyricsReturnsNil() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("song.wav"))

        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        try await model.addFolder(music)
        defer { model.shutdown() }

        #expect(await model.lyrics(for: music.appendingPathComponent("song.wav")) == nil)
        #expect(await model.lyrics(for: music.appendingPathComponent("absent.wav")) == nil)
    }

    @Test func oversizedSidecarIsRejectedRatherThanParsed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("song.wav"))
        // 3 MB of valid LRC exceeds the 2 MB sidecar bound.
        let line = String(repeating: "[00:01.00] lyric ", count: 1)
        try Data(String(repeating: line, count: 200_000).utf8).write(to: music.appendingPathComponent("song.lrc"))

        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        try await model.addFolder(music)
        defer { model.shutdown() }

        #expect(await model.lyrics(for: music.appendingPathComponent("song.wav")) == nil)
    }

    @Test func binaryGarbageSidecarIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("song.wav"))
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0xFF, 0x41]).write(to: music.appendingPathComponent("song.lrc"))

        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        try await model.addFolder(music)
        defer { model.shutdown() }

        #expect(await model.lyrics(for: music.appendingPathComponent("song.wav")) == nil)
    }
}
