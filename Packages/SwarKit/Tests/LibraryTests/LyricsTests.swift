import Testing
import Foundation
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
}
