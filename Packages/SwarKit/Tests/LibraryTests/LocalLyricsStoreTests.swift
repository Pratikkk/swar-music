import Foundation
import Testing
@testable import Library

struct LocalLyricsStoreTests {
    @Test func linkedFileSurvivesRestartReloadsEditsAndUnlinksWithoutDeleting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lyrics = root.appendingPathComponent("song.lrc")
        let file = root.appendingPathComponent("settings.json")
        try "[00:01]First".write(to: lyrics, atomically: true, encoding: .utf8)
        let store = LocalLyricsStore(file: file)
        try await store.attach(lyrics, to: "song")
        let reopened = LocalLyricsStore(file: file)
        #expect(try await reopened.associatedText("song") == "[00:01]First")
        try "[00:02]Edited".write(to: lyrics, atomically: true, encoding: .utf8)
        #expect(try await reopened.associatedText("song") == "[00:02]Edited")
        var settings = try await reopened.get("song")
        settings.bookmark = nil
        try await reopened.save(settings, for: "song")
        #expect(try await reopened.associatedText("song") == nil)
        #expect(FileManager.default.fileExists(atPath: lyrics.path))
    }

    @Test func settingsSurviveRestartAndAreIsolatedPerSong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = LocalLyricsStore(file: file)
        var value = LocalLyricsSettings()
        value.delay = -1.5
        try await store.save(value, for: "one")
        let reopened = LocalLyricsStore(file: file)
        #expect(try await reopened.get("one").delay == -1.5)
        #expect(try await reopened.get("two").delay == 0)
        #expect(try await reopened.get("two").bookmark == nil)
    }

    @Test func delaysMoveLineAndWordTimesWithoutMutatingOriginal() throws {
        let original = try #require(LyricsParser.parse("[00:10]<00:10>Hello <00:11>world", source: .custom))
        let shifted = original.delayed(by: -2)
        #expect(shifted.lines[0].time == 8)
        #expect(shifted.lines[0].words.map(\.time) == [8, 9])
        #expect(original.lines[0].time == 10)
        #expect(original.delayed(by: 2).lines[0].time == 12)
        #expect(original.delayed(by: .nan) == original)
        #expect(original.delayed(by: -20).lines[0].time == 0)
        let plain = try #require(LyricsParser.unsynced("Hello", source: .custom))
        #expect(plain.delayed(by: 2) == plain)
    }

    @Test func boundedReaderRejectsOversizedAndInvalidUTF8Files() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lrc")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: file)
        #expect(throws: (any Error).self) { try LocalLyricsStore.read(file) }
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        #expect(throws: (any Error).self) { try LocalLyricsStore.read(file) }
        try "[00:01]Hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(try LocalLyricsStore.read(file) == "[00:01]Hello")
    }
}
